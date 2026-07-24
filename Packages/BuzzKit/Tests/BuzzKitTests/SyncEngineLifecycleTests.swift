@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine lifecycle, discovery, and degradation", .timeLimit(.minutes(1)))
struct SyncEngineLifecycleTests {
    // MARK: - State machine

    /// The engine state mirrors the connection: `stopped → starting → running`, a
    /// backgrounded app rests in `suspended`, and every transition into `.ready`
    /// (fresh socket) — including a foreground resume — resets channel sync to
    /// `unsynced` and re-reconciles.
    @Test("Ready runs; suspend resets channel sync; resume re-reconciles")
    func stateTransitions() async throws {
        let socket1 = ScriptedRelay()
        let socket2 = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket1, socket2])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])
        let row = try build.row("m1", at: 1_700_000_005)
        // A short, exhausted head page so the reconcile completes deterministically.
        func page() throws -> Data {
            try WindowResponseBuilder.body([row, try build.headBounds(hasMore: false)])
        }

        #expect(await harness.engine.state == .stopped)
        await harness.http.enqueue(status: 200, body: try page())

        try await harness.engine.start()
        #expect(await harness.engine.state == .starting)

        try await driveAuth(harness.connection, socket1)
        await answerDiscovery(on: socket1, events: [metadata])
        await waitUntil { await harness.engine.state == .running }
        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        // Background past the (instant) grace window releases the socket.
        await harness.engine.enterBackground()
        await waitUntil { await harness.engine.state == .suspended }
        #expect(await harness.engine.channelSyncState("room") == .unsynced)

        // Foreground resumes on a fresh socket and re-runs discovery + reconcile.
        await harness.http.enqueue(status: 200, body: try page())
        await harness.engine.enterForeground()
        try await driveAuth(harness.connection, socket2)
        await answerDiscovery(on: socket2, events: [metadata])
        await waitUntil { await harness.engine.state == .running }
        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        await harness.engine.stop()
        #expect(await harness.engine.state == .stopped)
    }

    // MARK: - Discovery on ready

    /// Every `.ready` runs channel discovery — a one-shot query for the relay-signed
    /// group state that does not ride the live fan-out — ingests it, and reconciles
    /// each discovered channel's head.
    @Test("Discovers group state on ready and reconciles the discovered channel")
    func discoversOnReady() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])
        let roster = try build.relay.event(
            .groupMembers, "", tags: [["d", "room"], ["p", harness.selfPubkey]]
        )
        let row = try build.row("hello", at: 1_700_000_005)
        let bounds = try build.headBounds(hasMore: false)
        await harness.http.enqueue(status: 200, body: try WindowResponseBuilder.body([row, bounds]))

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [metadata, roster])

        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        // Discovery ingested the relay-signed group state through the choke point.
        #expect(try await harness.store.rowCount("channel") == 1)
        #expect(try await harness.store.rowCount("channel_member") == 1)
        // And the discovered channel's head was reconciled.
        #expect(await harness.http.requests.count == 1)
        #expect(try await harness.store.event(id: row.id) != nil)

        await harness.engine.stop()
    }

    // MARK: - Degradation fallback

    /// A `.degraded` window result withdraws the fast path for the session and falls
    /// back to assembling history over the standard WebSocket filter — no window
    /// retry, threads reassembled client-side by the projector.
    ///
    /// The channel lands `.fallbackSynced`, not `.synced`: the fallback is a single
    /// limit-bounded page over a possibly-open gap, so the watermark must hold (the
    /// P2-3 contiguity fix).
    @Test("A degraded window falls back to the standard WebSocket filter")
    func degradationFallback() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        // Known channel (seeded watermark) so reconcile runs.
        try await harness.store.executeForTest("""
        INSERT INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
        VALUES ('room', 1700000000, 'seed', 0)
        """)
        // The window round-trip never completes → degraded.
        await harness.http.enqueueFailure(.requestFailed("offline"))

        let fixtures = try EngineFixtures()
        let history1 = try fixtures.message("h1", in: "room", at: 1_700_000_005)
        let history2 = try fixtures.message("h2", in: "room", at: 1_700_000_006)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        // The fallback issues a standard history query scoped to the channel.
        let historySub = await awaitREQ(on: socket, matching: { isChannelHistoryREQ($0, channel: "room") })
        await socket.enqueue(EngineFrames.event(historySub, history1))
        await socket.enqueue(EngineFrames.event(historySub, history2))
        await socket.enqueue(EngineFrames.eose(historySub))

        await waitUntil { await harness.engine.channelSyncState("room") == .fallbackSynced }

        #expect(try await harness.store.event(id: history1.id) != nil)
        #expect(try await harness.store.event(id: history2.id) != nil)
        // The single failed window attempt was not retried; the fast path is gone.
        #expect(await harness.http.requests.count == 1)
        // The watermark held at its seed — the fallback never advanced it over the
        // unclosed gap below the recovered head.
        #expect(try await harness.store.channelWatermark("room")
            == WindowCursor(createdAt: 1_700_000_000, id: "seed"))

        await harness.engine.stop()
    }
}
