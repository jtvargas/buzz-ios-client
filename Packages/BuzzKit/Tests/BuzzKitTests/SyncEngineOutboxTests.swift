@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine outbox drain across kill and reconnect", .timeLimit(.minutes(1)))
struct SyncEngineOutboxTests {
    // MARK: - T3

    /// T3 — killed between send and OK. A message is enqueued and handed to the
    /// relay (the EVENT frame is recorded), then the app is killed before the OK.
    /// On restart the drain resends it verbatim; the relay's verdict — an `OK true`,
    /// or an `OK false duplicate:` — confirms it exactly once, leaving one row in
    /// the log and none in the outbox.
    @Test("Restart resends verbatim; OK true and duplicate both confirm once", arguments: [true, false])
    func killBetweenSendAndOK(directAccept: Bool) async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()

        let socket1 = ScriptedRelay()
        let harness1 = try EngineHarness(path: database.path, identity: identity, relays: [socket1])

        // Enqueued while offline; it persists as a pending row keyed by its own id.
        let queued = try await harness1.store.enqueue(
            content: "hello", in: "room-1", tags: [["h", "room-1"]], with: harness1.signer
        )

        try await harness1.engine.start()
        try await driveAuth(harness1.connection, socket1)
        await answerDiscovery(on: socket1)

        // The on-ready drain publishes it; kill before the relay answers.
        await awaitPublish(on: socket1, eventID: queued.event.id)
        await harness1.engine.stop()
        #expect(try await harness1.store.outboxCount() == 1)

        // Restart: same database file, fresh fakes.
        let socket2 = ScriptedRelay()
        let harness2 = try harness1.reopen(relays: [socket2])
        try await harness2.engine.start()
        try await driveAuth(harness2.connection, socket2)
        await answerDiscovery(on: socket2)

        // The drain resends the identical event; the relay accepts (or dedupes) it.
        await awaitPublish(on: socket2, eventID: queued.event.id)
        let verdict = directAccept
            ? EngineFrames.ok(queued.event.id, true)
            : EngineFrames.ok(queued.event.id, false, "duplicate: relay already has it")
        await socket2.enqueue(verdict)

        await waitUntil { (try? await harness2.store.outboxCount()) == 0 }
        #expect(try await harness2.store.outboxCount() == 0)
        #expect(try await harness2.store.count() == 1)
        let stored = try await harness2.store.event(id: queued.event.id)
        #expect(stored?.content == "hello")

        await harness2.engine.stop()
    }

    // MARK: - Drain on ready

    /// A message enqueued before the socket is live is drained the moment the
    /// connection reaches `.ready` — the "drain on every transition into ready"
    /// rule — without an explicit retry.
    @Test("A pending message drains automatically on the next ready")
    func drainsOnReady() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let queued = try await harness.store.enqueue(
            content: "queued offline", in: "room-1", tags: [["h", "room-1"]], with: harness.signer
        )
        #expect(try await harness.store.outboxCount() == 1)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        await awaitPublish(on: socket, eventID: queued.event.id)
        await socket.enqueue(EngineFrames.ok(queued.event.id, true))

        await waitUntil { (try? await harness.store.outboxCount()) == 0 }
        #expect(try await harness.store.outboxCount() == 0)
        #expect(try await harness.store.count() == 1)

        await harness.engine.stop()
    }
}
