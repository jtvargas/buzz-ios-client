@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// ``SyncEngine/refresh()`` — the pull-to-refresh path.
///
/// On a live connection it re-runs exactly what a fresh socket runs, and awaits it, so
/// the spinner lasts as long as the catch-up. On a dead one it stops the waiting: the
/// connection reopens now instead of sitting out its backoff.
@Suite("SyncEngine refresh", .timeLimit(.minutes(1)))
struct SyncEngineRefreshTests {
    /// A short, exhausted head page, so a reconcile completes deterministically.
    private func page(_ build: WindowResponseBuilder, id: String, at seconds: Int64) throws -> Data {
        try WindowResponseBuilder.body([try build.row(id, at: seconds), try build.headBounds(hasMore: false)])
    }

    /// Answers the next discovery REQ the client has *not* been answered on yet.
    ///
    /// ``answerDiscovery(on:events:)`` cannot serve a second catch-up: the relay keeps
    /// every frame it was sent, so the scan always finds the connect's own discovery
    /// REQ again and answers an id whose one-shot query has long since closed — leaving
    /// the refresh's real query waiting for an EOSE that went to a dead subscription.
    @discardableResult
    private func answerNextDiscovery(
        on relay: ScriptedRelay, excluding seen: Set<String>, events: [NostrEvent]
    ) async -> String {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame),
                      isDiscoveryREQ(request.filters),
                      !seen.contains(request.id)
                else { continue }
                for event in events { await relay.enqueue(EngineFrames.event(request.id, event)) }
                await relay.enqueue(EngineFrames.eose(request.id))
                return request.id
            }
            await Task.yield()
        }
    }

    /// Waits out the catch-up a fresh socket runs, so a test that means to start a
    /// *second* one is not silently joined to the first.
    private func waitForCatchUpToFinish(_ engine: SyncEngine) async {
        await waitUntil { await engine.readyWorkInFlight == false }
    }

    @Test("A refresh on a live connection re-runs discovery and the head reconcile")
    func refreshRerunsTheCatchUp() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])

        await harness.http.enqueue(status: 200, body: try page(build, id: "m1", at: 1_700_000_005))
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        let connectDiscovery = await answerNextDiscovery(on: socket, excluding: [], events: [metadata])
        await waitUntil { await harness.engine.channelSyncState("room") == .synced }
        await waitForCatchUpToFinish(harness.engine)

        let windowRequestsBeforeRefresh = await harness.http.requests.count

        // The pull. A second discovery REQ goes out on the same socket and a second
        // head window is fetched — the same work a reconnect would do, without one.
        await harness.http.enqueue(status: 200, body: try page(build, id: "m2", at: 1_700_000_009))
        async let refreshed: Void = harness.engine.refresh()
        await answerNextDiscovery(on: socket, excluding: [connectDiscovery], events: [metadata])
        await refreshed

        #expect(await harness.http.requests.count > windowRequestsBeforeRefresh)
        #expect(await harness.engine.channelSyncState("room") == .synced)
        // The refreshed page landed in the store, which is what the reader pulled for.
        let stored = try await harness.store.knownChannels()
        #expect(stored.contains("room"))

        await harness.engine.stop()
    }

    @Test("A refresh joins a catch-up already in flight rather than racing it")
    func refreshJoinsInFlightCatchUp() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])

        await harness.http.enqueue(status: 200, body: try page(build, id: "m1", at: 1_700_000_005))
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)

        // Pull *during* the connect's own catch-up: discovery has not been answered
        // yet, so the on-ready work is parked. A second reconcile of `room` here would
        // race the first on the watermark, so the refresh must join instead.
        async let refreshed: Void = harness.engine.refresh()
        await answerDiscovery(on: socket, events: [metadata])
        await refreshed

        // One catch-up ran, not two: the single enqueued page was enough to reach
        // `.synced`, and a second reconcile would have found the queue empty and left
        // the channel unsynced.
        #expect(await harness.engine.channelSyncState("room") == .synced)
        #expect(await harness.http.requests.count == 1)

        await harness.engine.stop()
    }

    @Test("A refresh on a suspended engine reopens the connection")
    func refreshReopensASuspendedConnection() async throws {
        let socket1 = ScriptedRelay()
        let socket2 = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket1, socket2]
        )

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])

        await harness.http.enqueue(status: 200, body: try page(build, id: "m1", at: 1_700_000_005))
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket1)
        await answerDiscovery(on: socket1, events: [metadata])
        await waitUntil { await harness.engine.state == .running }

        // Backgrounded past the (instant) grace window: the socket is released.
        await harness.engine.enterBackground()
        await waitUntil { await harness.engine.state == .suspended }

        // The pull opens a fresh socket rather than waiting for a scene-phase change.
        await harness.http.enqueue(status: 200, body: try page(build, id: "m2", at: 1_700_000_009))
        await harness.engine.refresh()
        try await driveAuth(harness.connection, socket2)
        await answerDiscovery(on: socket2, events: [metadata])
        await waitUntil { await harness.engine.state == .running }
        await waitUntil { await harness.engine.channelSyncState("room") == .synced }

        await harness.engine.stop()
    }

    @Test("A refresh on a stopped engine does nothing")
    func refreshOnAStoppedEngineDoesNothing() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let build = try WindowResponseBuilder(channel: "room")
        let metadata = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])

        await harness.http.enqueue(status: 200, body: try page(build, id: "m1", at: 1_700_000_005))
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [metadata])
        await waitUntil { await harness.engine.state == .running }

        // Signed out. A pull on a screen still on its way off must not reopen a socket
        // for an identity that has been torn down.
        await harness.engine.stop()
        let requestsAfterStop = await harness.http.requests.count

        await harness.engine.refresh()

        #expect(await harness.engine.state == .stopped)
        #expect(await harness.http.requests.count == requestsAfterStop)

        await harness.engine.stop()
    }
}
