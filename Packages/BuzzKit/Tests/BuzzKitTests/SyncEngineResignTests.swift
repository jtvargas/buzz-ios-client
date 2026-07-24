@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("SyncEngine stale-timestamp re-sign drains end to end", .timeLimit(.minutes(1)))
struct SyncEngineResignTests {
    // MARK: - T4 (engine level)

    /// T4 end to end, driven through the step-6 ``EngineHarness``: a message composed
    /// offline is drained twenty minutes later, so its original `created_at` trips the
    /// relay's ±15-minute ingest gate. The scripted relay rejects the first send with
    /// `OK false "invalid: event timestamp too far from server time"`; the engine must
    /// re-sign through the store — a fresh `created_at` and therefore a new id — resend,
    /// and confirm on the scripted `OK true`. The invariant the criterion pins: exactly
    /// one message carrying m2's content lands in the log, and the original id appears in
    /// neither the log nor the outbox.
    ///
    /// This is the store-level `OutboxDispositionTests.resolveInvalidStaleReSigns` proven
    /// over the whole wired stack — the connection publishes, the OK classifier routes
    /// the verdict, the engine's `handlePublishFailure` resends the re-signed row, and
    /// the store's transactional identity swap holds throughout.
    @Test("A stale offline send is re-signed on the relay's invalid verdict and lands once")
    func staleDrainReSignsAndLandsOnce() async throws {
        let database = TempDatabase()
        defer { database.remove() }

        // The store runs on a windable clock: the message is signed at `start`, the clock
        // then advances past the stale threshold before the drain, so the send is aged in
        // exactly the way an offline compose then a much-later reconnect would age it.
        let start: TimeInterval = 1_700_000_000
        let clock = MutableDateClock(Date(timeIntervalSince1970: start))

        let socket = ScriptedRelay()
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket], storeClock: clock.reader
        )

        // Composed offline: a pending row stamped at `start`.
        let queued = try await harness.store.enqueue(
            content: "m2", in: "room-1", tags: [["h", "room-1"]], with: harness.signer
        )
        let oldID = queued.event.id
        #expect(queued.event.createdAt == Int64(start))

        // Twenty minutes pass before the socket comes up — past the ten-minute stale
        // threshold, so the relay's fifteen-minute gate is now in play.
        clock.advance(by: 1200)

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)

        // The on-ready drain publishes the original event; the relay closes its
        // timestamp window on it.
        await awaitPublish(on: socket, eventID: oldID)
        await socket.enqueue(
            EngineFrames.ok(oldID, false, "invalid: event timestamp too far from server time")
        )

        // The engine re-signs (fresh created_at at the wound-forward clock, new id) and
        // resends. Its id is unpredictable to the test, so we read it off the wire and
        // answer it.
        let newID = await awaitPublish(on: socket, excluding: oldID)
        #expect(newID != oldID)
        await socket.enqueue(EngineFrames.ok(newID, true))

        await waitUntil { (try? await harness.store.outboxCount()) == 0 }

        // Exactly one message, carrying the original content, under the fresh id; the
        // original id is gone from both the outbox and the log — safe, because the relay
        // never stored it (had it, the verdict would have been `duplicate:`).
        #expect(try await harness.store.outboxCount() == 0)
        #expect(try await harness.store.count(kind: .channelMessage) == 1)
        #expect(try await harness.store.event(id: newID)?.content == "m2")
        #expect(try await harness.store.event(id: oldID) == nil)

        // The re-signed event carries the wound-forward timestamp, so a second gate check
        // would find it fresh — the re-sign is self-limiting and cannot loop.
        #expect(try await harness.store.event(id: newID)?.createdAt == Int64(start) + 1200)

        await harness.engine.stop()
    }
}
