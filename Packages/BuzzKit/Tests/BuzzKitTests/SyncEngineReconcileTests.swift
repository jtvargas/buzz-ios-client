@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine reconcile closes the offline gap", .timeLimit(.minutes(1)))
struct SyncEngineReconcileTests {
    // MARK: - T5

    /// T5 — reconcile closes the offline gap. Watermark sits at e5; the head page
    /// [e12…e8] reports `has_more` with a cursor, page 2 [e7…e4] overlaps the
    /// watermark. The engine must stop at page 2 (no third request), advance the
    /// watermark to e12's cursor, and store e4…e12 once each.
    @Test("Pages the head down to the watermark, stops on overlap, advances to the head's newest")
    func closesGap() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        // e1…e12 with strictly increasing created_at, so the composite cursor order
        // reduces to timestamp order and e12 is unambiguously the head.
        let events = try (1 ... 12).map { index in
            try build.row("m\(index)", at: 1_700_000_000 + Int64(index))
        }
        func cursor(_ index: Int) -> WindowCursor {
            WindowCursor(createdAt: events[index - 1].createdAt, id: events[index - 1].id)
        }

        // Seed the durable watermark at e5, as if a prior session synced that far.
        try await harness.store.executeForTest("""
        INSERT INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
        VALUES ('room', \(cursor(5).createdAt), '\(cursor(5).id)', 0)
        """)

        // Head page [e12…e8], has_more, next_cursor = e8.
        let headBounds = try build.headBounds(hasMore: true, nextCursor: cursor(8))
        let page1 = try WindowResponseBuilder.body([
            events[11], events[10], events[9], events[8], events[7], headBounds,
        ])
        // Page 2 [e7…e4], bound to the head's next_cursor, exhausted.
        let page2Bounds = try build.bounds(
            dSuffix: cursor(8).dTagSuffix,
            content: WindowResponseBuilder.boundsContent(hasMore: false, nextCursor: nil)
        )
        let page2 = try WindowResponseBuilder.body([
            events[6], events[5], events[4], events[3], page2Bounds,
        ])

        await harness.http.enqueue(status: 200, body: page1)
        await harness.http.enqueue(status: 200, body: page2)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        // No third page was requested — the overlap stopped the loop.
        #expect(await harness.http.requests.count == 2)
        // The watermark advanced to the head page's newest row, and only there.
        #expect(try await harness.store.channelWatermark("room") == cursor(12))
        // e4…e12 stored exactly once each; the two pages that overlapped deduped.
        #expect(try await harness.store.count(kind: .channelMessage) == 9)
        for index in 4 ... 12 {
            #expect(try await harness.store.event(id: events[index - 1].id) != nil)
        }

        await harness.engine.stop()
    }

    /// A fresh channel with no stored watermark pages the whole history until the
    /// relay reports `has_more = false`, then advances the watermark to the head.
    @Test("A never-synced channel pages to exhaustion, then advances to the head")
    func fromScratchPagesToExhaustion() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let newest = try build.row("newest", at: 1_700_000_002)
        let oldest = try build.row("oldest", at: 1_700_000_001)
        let bounds = try build.headBounds(hasMore: false)
        let page = try WindowResponseBuilder.body([newest, oldest, bounds])
        await harness.http.enqueue(status: 200, body: page)

        // Make the channel known without a watermark: a metadata row from discovery.
        let metadata = try build.relay.event(
            .groupMetadata, "", tags: [["d", "room"], ["name", "Room"]]
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [metadata])

        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        #expect(await harness.http.requests.count == 1)
        #expect(try await harness.store.channelWatermark("room")
            == WindowCursor(createdAt: newest.createdAt, id: newest.id))
        #expect(try await harness.store.count(kind: .channelMessage) == 2)

        await harness.engine.stop()
    }
}
