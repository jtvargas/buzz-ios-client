import Foundation
@testable import NostrCore
import Testing

/// The handshake deadline: the bound on how long an opened socket may rest below
/// `.ready`.
///
/// The gap it closes is one the idle watchdog cannot see. An answered ping counts as
/// activity, so it resets the idle clock — and a peer that pongs while never speaking
/// the protocol is therefore never judged dead. A relay that accepts the socket and
/// issues no challenge, or takes the auth answer and never verdicts it, left the
/// connection resting below `.ready` for the life of the process.
///
/// Most of these drive ``RelayConnection/handshakeDeadlineExpired(generation:)``
/// directly, so the decision is asserted without spending the deadline. Two spend a
/// deliberately tiny one instead, because "the timer is actually armed" is not a fact
/// a direct call can establish.
@Suite("RelayConnection handshake deadline")
struct RelayConnectionHandshakeDeadlineTests {
    /// Inert except for the handshake bounds named by the caller — so a test that
    /// wants to prove the arming spends milliseconds and nothing else fires.
    private func handshakeConfig(
        timeout: Duration = .seconds(3600),
        foreground: Duration = .seconds(3600)
    ) -> RelayConnectionConfig {
        RelayConnectionConfig(
            backgroundGrace: .seconds(3600),
            pingInterval: .seconds(3600),
            pingDeadline: .seconds(3600),
            idleTimeout: .seconds(3600),
            handshakeTimeout: timeout,
            foregroundHandshakeDeadline: foreground,
            authTimeout: .seconds(3600),
            queryTimeout: .seconds(3600),
            publishTimeout: .seconds(3600)
        )
    }

    // MARK: - The stall the idle watchdog cannot see

    @Test("A socket that never receives its challenge is dropped and retried", .timeLimit(.minutes(1)))
    func silentRelayIsRetried() async throws {
        let signer = try InMemorySigner()
        let silent = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([silent, second])
        let connection = makeInertConnection(signer: signer, transports: transports)

        // The socket opens and the relay says nothing at all — no AUTH challenge,
        // ever. Nothing below `.ready` moves on its own from here.
        try await connection.connect()
        await waitForState(connection) { $0 == .connecting }

        await connection.handshakeDeadlineExpired(generation: connection.currentGeneration)

        // The stalled socket is dropped and a fresh one opened, which authenticates
        // normally: the app recovers rather than resting in `.connecting` forever.
        await waitUntil { await transports.vendedCount == 2 }
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    @Test("A challenge answered but never verdicted is dropped and retried", .timeLimit(.minutes(1)))
    func unansweredAuthIsRetried() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        // Challenge, answer — and then no `OK`. The connection parks in
        // `.authenticating`, which is where a lost verdict leaves it.
        await first.enqueue(Frames.challenge("challenge-1"))
        _ = await first.awaitSend(index: 0)
        await waitForState(connection) { $0 == .authenticating }

        await connection.handshakeDeadlineExpired(generation: connection.currentGeneration)

        await waitUntil { await transports.vendedCount == 2 }
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    // MARK: - What the deadline must not touch

    @Test("The deadline does not disturb a socket that reached ready", .timeLimit(.minutes(1)))
    func readySocketSurvivesALateDeadline() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // A deadline firing against a handshake that has since landed — the race
        // between the timer and the last `OK`. The socket is kept.
        await connection.handshakeDeadlineExpired(generation: connection.currentGeneration)

        #expect(await connection.state == .ready)
        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }

    @Test("A deadline from a superseded socket is ignored", .timeLimit(.minutes(1)))
    func staleDeadlineIsIgnored() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        let stale = await connection.currentGeneration

        // A drop replaces the socket, so the first one's deadline is now stale. Were
        // it honoured it would tear down the *replacement* mid-handshake.
        await connection.handleConnectionLost(generation: stale)
        await waitUntil { await transports.vendedCount == 2 }
        let current = await connection.currentGeneration

        await connection.handshakeDeadlineExpired(generation: stale)

        #expect(await connection.currentGeneration == current)
        #expect(await transports.vendedCount == 2)

        await connection.stop()
    }

    // MARK: - That the deadline is armed at all

    @Test("Opening a socket arms the deadline", .timeLimit(.minutes(1)))
    func connectArmsTheDeadline() async throws {
        let signer = try InMemorySigner()
        let transports = TransportQueue([FakeRelay()])
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: handshakeConfig(timeout: .milliseconds(20)),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in }
        )

        // Nothing is scripted, so every socket this vends stalls below `.ready` and is
        // replaced by the next. A second transport is proof the timer fired on its own
        // — the only fact a direct call to the expiry cannot establish.
        try await connection.connect()
        await waitUntil { await transports.vendedCount >= 2 }

        await connection.stop()
    }

    @Test("Foregrounding mid-handshake re-arms the deadline at the tighter bound", .timeLimit(.minutes(1)))
    func foregroundMidHandshakeRearmsTheDeadline() async throws {
        let signer = try InMemorySigner()
        let transports = TransportQueue([FakeRelay()])
        // The base bound is inert, so only the *foreground* arming can fire here.
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: handshakeConfig(foreground: .milliseconds(20)),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in }
        )

        try await connection.connect()
        await waitForState(connection) { $0 == .connecting }
        #expect(await transports.vendedCount == 1) // the inert base bound will not fire

        // The app comes back while the handshake is still in flight. Before this,
        // `foreground()` returned without doing anything, on the reasoning that a
        // handshake resolves itself — which a handshake frozen by backgrounding, on a
        // socket the OS may since have dropped, need not.
        await connection.foreground()

        await waitUntil { await transports.vendedCount >= 2 }

        await connection.stop()
    }
}
