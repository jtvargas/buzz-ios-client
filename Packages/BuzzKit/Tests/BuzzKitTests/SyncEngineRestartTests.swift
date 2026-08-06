@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine survives a literal kill mid-backfill", .timeLimit(.minutes(1)))
struct SyncEngineRestartTests {
    // MARK: - T1 (fresh-restart variant)

    /// T1 with a literal kill rather than a within-session reconnect. The landed
    /// `SyncEngineBackfillTests.killMidBackfill` fails one socket and reconnects on the
    /// next within the *same* engine, proving the manager never arms a replay cursor
    /// without an EOSE. This variant proves the same no-loss guarantee across a process
    /// death: mid-backfill the engine is torn down and a *fresh* engine reopens the same
    /// database with fresh fakes. Because no EOSE ever landed, the fresh engine's live
    /// REQ carries the original filter (no cursor to inherit), the relay replays the full
    /// history, and the persisted log dedupes the overlap so every event is stored
    /// exactly once.
    @Test("Kill mid-backfill, reopen the same db, and the full replay dedupes to ten")
    func killAndReopenMidBackfill() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()

        let socket1 = ScriptedRelay()
        let harness1 = try EngineHarness(
            path: database.path, identity: identity, relays: [socket1], batchSize: 2
        )

        // Ten stored events; e-indices count up with created_at, so `newestFirst` is the
        // order a relay replays a backfill in.
        let fixtures = try EngineFixtures()
        let events = try (1 ... 10).map { index in
            try fixtures.message("m\(index)", in: "room", at: 1_700_000_000 + Int64(index))
        }
        let newestFirst = Array(events.reversed()) // e10 … e1

        try await harness1.engine.start()
        try await driveAuth(harness1.connection, socket1)
        await answerDiscovery(on: socket1)
        // Channel messages ride the standing per-channel content sub; open "room"'s.
        try await harness1.engine.subscribeChannelContent("room")

        // e10…e6 arrive as backfill with no EOSE. batchSize 2 flushes e10,e9 and e8,e7;
        // e6 stays buffered in the manager and is lost with the process — the store holds
        // exactly four when the app dies.
        let sub1 = await awaitChannelContentREQ(on: socket1, channel: "room")
        for event in newestFirst.prefix(5) {
            await socket1.enqueue(EngineFrames.event(sub1, event))
        }
        await waitUntil { (try? await harness1.store.count(kind: .channelMessage)) == 4 }

        // The literal kill: tear the engine down. No EOSE was ever delivered, so nothing
        // durable records a replay position.
        await harness1.engine.stop()
        #expect(try await harness1.store.count(kind: .channelMessage) == 4)

        // Reopen the same database file with a fresh engine and fresh fakes.
        let socket2 = ScriptedRelay()
        let harness2 = try harness1.reopen(relays: [socket2])

        try await harness2.engine.start()
        try await driveAuth(harness2.connection, socket2)
        // A fresh engine on the reopened db has no standing channel subs yet; the
        // channel is not in group state (discovery was empty), so open "room" again.
        try await harness2.engine.subscribeChannelContent("room")

        // The re-REQ carries the original content filter — since = now − 5, no `until` —
        // because a fresh engine has no armed replay cursor to inherit.
        let replayFilter = await awaitChannelContentFilter(on: socket2, channel: "room")
        #expect(replayFilter.since == harness2.nowSeconds - 5)
        #expect(replayFilter.until == nil)

        await answerDiscovery(on: socket2)
        let sub2 = await awaitChannelContentREQ(on: socket2, channel: "room")
        for event in newestFirst {
            await socket2.enqueue(EngineFrames.event(sub2, event))
        }
        await socket2.enqueue(EngineFrames.eose(sub2))

        // The full replay dedupes against the four already-persisted events; the store
        // converges on all ten, each exactly once.
        await waitUntil { (try? await harness2.store.count(kind: .channelMessage)) == 10 }
        #expect(try await harness2.store.count(kind: .channelMessage) == 10)
        for event in events {
            #expect(try await harness2.store.event(id: event.id) != nil)
        }

        await harness2.engine.stop()
    }

    @Test("Six mixed recent destinations persist in MRU order across a fresh engine")
    func recentConversationPriorityPersistsAcrossRestart() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()
        let harness1 = try EngineHarness(
            path: database.path,
            identity: identity,
            relays: [ScriptedRelay()]
        )

        try await harness1.engine.start()
        await harness1.engine.setActiveChannel("channel-a")
        await harness1.engine.setActiveChannel("channel-b")
        await harness1.engine.setActiveThread(channel: "channel-a", root: "thread-a-1")
        await harness1.engine.setActiveThread(channel: "channel-b", root: "thread-b-1")
        await harness1.engine.setActiveThread(channel: "channel-b", root: "thread-b-2")
        await harness1.engine.setActiveChannel("channel-c")
        await harness1.engine.setActiveThread(channel: "channel-c", root: "thread-c-1")
        // Revisit an existing destination: it moves to the front rather than occupying a
        // seventh slot, and the oldest channel falls out of the bounded list.
        await harness1.engine.setActiveChannel("channel-b")

        let expected: [RecentConversationDestination] = [
            .channel("channel-b"),
            .thread(channelID: "channel-c", rootID: "thread-c-1"),
            .channel("channel-c"),
            .thread(channelID: "channel-b", rootID: "thread-b-2"),
            .thread(channelID: "channel-b", rootID: "thread-b-1"),
            .thread(channelID: "channel-a", rootID: "thread-a-1"),
        ]
        #expect(
            try await harness1.store.recentConversationDestinations(identity: harness1.selfPubkey)
                == expected
        )
        await harness1.engine.stop()

        let harness2 = try harness1.reopen(relays: [ScriptedRelay()])
        try await harness2.engine.start()
        #expect(await harness2.engine.recentConversationDestinations == expected)
        await harness2.engine.stop()
    }
}
