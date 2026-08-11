@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The two halves of "a queued send goes first": it drains the moment the socket
/// authenticates rather than behind the on-ready catch-up, and a send made while the
/// connection is down asks it to come back instead of waiting the backoff out.
@Suite("SyncEngine send priority", .timeLimit(.minutes(1)))
struct SyncEngineSendPriorityTests {
    /// A bounded poll that falls *through* on expiry rather than trapping, so the
    /// `#expect` after it still prints what the state actually was.
    ///
    /// Deliberately not the shared ``waitUntil(_:)``: that one spins until its predicate
    /// holds, so a regression in this suite would blow the time limit rather than fail —
    /// and everything here is a race, which is exactly where an unbounded spin turns a
    /// fast red into a sixty-second one.
    ///
    /// Five seconds is far more than any wait here needs — a SQLite insert, an actor hop,
    /// a socket construction — and the point of the ceiling is only that a broken
    /// predicate reports rather than hangs.
    private static func waitUntil(
        within limit: Duration = .seconds(5),
        _ condition: @Sendable () async -> Bool
    ) async {
        let deadline = ContinuousClock.now + limit
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func publishedIDs(on relay: ScriptedRelay) async -> [String] {
        await relay.frames().compactMap { publishedEventID($0) }
    }

    /// Waits for the engine to see the socket go live, then drops it and waits for the
    /// engine to see *that*.
    ///
    /// Both halves are load-bearing, and the first one is the whole reason this exists.
    /// The engine tracks the connection through an `AsyncStream`, so its state trails the
    /// socket's: `!= .running` is **already true** while the socket is still connecting and
    /// authenticating. A test that only waits for `!= .running` therefore returns on its
    /// first poll, before the connection has ever been up — and the send that follows lands
    /// on an engine that is about to become `.running`, takes the drain path instead of the
    /// nudge, and the assertion fails for a reason that has nothing to do with the code
    /// under test. That cost a red CI run and about forty minutes; waiting for the positive
    /// first is what makes the negative mean something.
    private static func dropSocketAfterGoingLive(
        _ harness: EngineHarness,
        _ relay: ScriptedRelay
    ) async {
        await waitUntil { await harness.engine.state == .running }
        #expect(await harness.engine.state == .running)

        await relay.enqueueFailure(.connectionClosed)
        await waitUntil { await harness.engine.state != .running }
        #expect(await harness.engine.state != .running)
    }

    // MARK: - Drain ahead of the catch-up

    /// A queued send is published on `.ready` itself, ahead of the on-ready pass.
    ///
    /// Discovery is deliberately never answered, which is the whole point: the drain used
    /// to sit at the *end* of that pass — in production behind the authoritative directory
    /// fetch as well — so a first query the relay does not answer meant the row was never
    /// published at all, not merely published late. Publishing it here, with the pass still
    /// parked on its opening query, is the property.
    @Test("a queued send publishes before the on-ready catch-up has answered anything")
    func drainsAheadOfCatchUp() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        let queued = try await harness.store.enqueue(
            content: "queued offline", in: "room-1", tags: [["h", "room-1"]], with: harness.signer
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)

        await Self.waitUntil { await Self.publishedIDs(on: socket).contains(queued.event.id) }
        #expect(await Self.publishedIDs(on: socket).contains(queued.event.id))

        await harness.engine.stop()
    }

    // MARK: - The send-side reconnect nudge

    /// A send made while the connection is backing off asks it to reopen now.
    ///
    /// The backoff is parked rather than instant (the harness default elapses
    /// immediately), so the connection cannot recover on its own and a second socket can
    /// only come from the nudge. Without it this test waits out its bound and fails.
    @Test("a send while backing off reopens the socket instead of waiting the backoff out")
    func sendReopensABackingOffConnection() async throws {
        let first = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [first],
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, first)

        await Self.dropSocketAfterGoingLive(harness, first)
        #expect(await harness.transports.vendedCount == 1)

        _ = try await harness.engine.enqueue(content: "hello", in: "room-1", tags: [["h", "room-1"]])

        await Self.waitUntil { await harness.transports.vendedCount == 2 }
        let vended = await harness.transports.vendedCount
        let connectionState = await harness.connection.state
        #expect(vended == 2, "vended=\(vended) connection=\(String(describing: connectionState))")

        await harness.engine.stop()
    }

    /// The nudge is rate-limited, so a run of sends cannot retry a dead network on a tight
    /// loop.
    ///
    /// Every socket after the first refuses its connect, so each nudge lands straight back
    /// in the parked backoff and another nudge would be visible as another vended
    /// transport. The engine clock is steppable because the limit is measured on it: the
    /// second send is inside the window and must produce nothing, and the third — after
    /// the clock passes ``SyncEngineConfig/connectionNudgeInterval`` — must produce a
    /// socket, which is what tells a working rate limit apart from a nudge that simply
    /// stopped happening.
    @Test("a second send inside the nudge window does not restart the reconnect")
    func nudgeIsRateLimited() async throws {
        let first = ScriptedRelay()
        let second = ScriptedRelay()
        let third = ScriptedRelay()
        await second.failConnect(with: .connectFailed("refused"))
        await third.failConnect(with: .connectFailed("refused"))

        let database = TempDatabase()
        defer { database.remove() }
        let clock = SteppableClock(seconds: 1_700_000_000)
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [first, second, third],
            engineClock: { clock.now },
            backoffSleep: { _ in try await Task.sleep(for: .seconds(3600)) }
        )

        try await harness.engine.start()
        try await driveAuth(harness.connection, first)

        await Self.dropSocketAfterGoingLive(harness, first)

        _ = try await harness.engine.enqueue(content: "one", in: "room-1", tags: [["h", "room-1"]])
        await Self.waitUntil { await harness.transports.vendedCount == 2 }
        #expect(await harness.transports.vendedCount == 2)

        // Asserting that something did *not* happen, so this dwells rather than polls — a
        // poll for absence returns on its first pass and proves nothing. The duration is a
        // sensitivity knob, not a correctness requirement: too short only weakens the test.
        _ = try await harness.engine.enqueue(content: "two", in: "room-1", tags: [["h", "room-1"]])
        try await Task.sleep(for: .milliseconds(200))
        #expect(await harness.transports.vendedCount == 2)

        clock.advance(by: 6)
        _ = try await harness.engine.enqueue(content: "three", in: "room-1", tags: [["h", "room-1"]])
        await Self.waitUntil { await harness.transports.vendedCount == 3 }
        #expect(await harness.transports.vendedCount == 3)

        await harness.engine.stop()
    }
}
