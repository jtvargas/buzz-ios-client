import Foundation
@testable import NostrCore
import Testing

@Suite("RelayConnection lifecycle, watchdog, and generation guard")
struct RelayConnectionLifecycleTests {
    private func watchdogConfig() -> RelayConnectionConfig {
        RelayConnectionConfig(
            reconnectPolicy: .default,
            backgroundGrace: .seconds(3600),
            pingInterval: .seconds(25),
            pingDeadline: .seconds(10),
            idleTimeout: .seconds(40),
            authTimeout: .seconds(3600),
            queryTimeout: .seconds(3600)
        )
    }

    // MARK: - Generation guard

    @Test("A frame stamped with a superseded generation is dropped")
    func generationGuardDropsStaleFrames() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let generation = await connection.currentGeneration
        let inbound = await connection.inbound()

        let stale = try await signer.sign(kind: .channelMessage, content: "stale")
        let live = try await signer.sign(kind: .channelMessage, content: "live")

        // Fed stale-first: were the stale frame not dropped, it would arrive
        // before the live one.
        await connection.handle(frameText: Frames.event("stale-sub", stale), generation: generation - 1)
        await connection.handle(frameText: Frames.event("live-sub", live), generation: generation)

        var iterator = inbound.makeAsyncIterator()
        let first = await iterator.next()
        guard case let .event(subscriptionID, event) = first else {
            Issue.record("expected an event, got \(String(describing: first))")
            return
        }
        #expect(subscriptionID == "live-sub")
        #expect(event == live)

        await connection.stop()
    }

    // MARK: - Frame routing

    @Test("EVENT, EOSE, and CLOSED for a non-query subscription route to the inbound feed")
    func routesSubscriptionFramesToInbound() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let inbound = await connection.inbound()
        var iterator = inbound.makeAsyncIterator()

        let event = try await signer.sign(kind: .channelMessage, content: "routed")
        await relay.enqueue(Frames.event("live-1", event))
        await relay.enqueue(Frames.eose("live-1"))
        await relay.enqueue(Frames.closed("live-1", "restricted: gone"))

        #expect(await iterator.next() == .event(subscriptionID: "live-1", event: event))
        #expect(await iterator.next() == .endOfStoredEvents(subscriptionID: "live-1"))
        #expect(await iterator.next() == .closed(subscriptionID: "live-1", reason: .restricted("gone")))

        await connection.stop()
    }

    // MARK: - Watchdog

    @Test("Idle past the hard bound declares the connection dead and reconnects", .timeLimit(.minutes(1)))
    func watchdogIdleTimeoutReconnects() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports, config: watchdogConfig())

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        let generation = await connection.currentGeneration
        await first.setIdle(.seconds(50)) // past idleTimeout (40s)
        await connection.performLivenessCheck(generation: generation, transport: first)

        await waitUntil { await second.connectAttempts.count >= 1 }
        #expect(await transports.vendedCount == 2)

        await connection.stop()
    }

    @Test("An unanswered ping past the soft bound declares the connection dead and reconnects", .timeLimit(.minutes(1)))
    func watchdogPingFailureReconnects() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports, config: watchdogConfig())

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        let generation = await connection.currentGeneration
        await first.setIdle(.seconds(30)) // between pingInterval (25s) and idleTimeout (40s)
        await first.failPings(with: .connectionClosed)
        await connection.performLivenessCheck(generation: generation, transport: first)

        await waitUntil { await second.connectAttempts.count >= 1 }
        #expect(await transports.vendedCount == 2)

        await connection.stop()
    }

    // MARK: - Background / foreground

    @Test("Backgrounding past the grace window suspends the connection")
    func backgroundGraceSuspends() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let graceGate = Gate()
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in },
            graceSleep: { try await graceGate.wait($0) }
        )

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        await connection.background()
        #expect(await connection.state == .ready) // grace has not elapsed yet

        await graceGate.release()
        await waitForState(connection) { $0 == .suspended }
        #expect(await connection.state == .suspended)

        await connection.stop()
    }

    @Test("Foregrounding within the grace window keeps the connection")
    func foregroundWithinGraceKeepsConnection() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let graceGate = Gate()
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in },
            graceSleep: { try await graceGate.wait($0) }
        )

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        await connection.background()
        await connection.foreground() // cancels the grace timer before it elapses

        // The grace timer was cancelled, so the socket is kept: the state stays
        // ready and no second transport is ever vended.
        #expect(await connection.state == .ready)
        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }

    @Test("Foregrounding cancels a pending backoff and reconnects immediately", .timeLimit(.minutes(1)))
    func foregroundCancelsBackoffAndReconnects() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let backoffGate = Gate()
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            backoffSleep: { try await backoffGate.wait($0) }
        )

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        // The socket drops; the reconnect enters backoff and parks on the gate.
        await first.enqueueFailure(.connectionClosed)
        await waitForState(connection) {
            if case .backingOff = $0 { return true }
            return false
        }

        // Foreground reconnects at once with the next socket — the backoff gate
        // is never released.
        await connection.foreground()
        await waitUntil { await transports.vendedCount == 2 }
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    // MARK: - resetAfter wiring

    @Test(
        "A connection healthy past resetAfter resets the reconnect counter on its next failure",
        .timeLimit(.minutes(1))
    )
    func healthyConnectionResetsBackoffCounter() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let failing = FakeRelay()
        await failing.failConnect(with: .connectFailed("refused"))
        let third = FakeRelay()
        let transports = TransportQueue([first, failing, third])

        let clock = MutableClock()
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30), resetAfter: .seconds(30))
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(policy: policy),
            makeTransport: { await transports.next() },
            now: { clock.current },
            backoffSleep: { _ in }
        )

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        // First socket up only briefly: its drop must not reset the counter, so
        // the counter climbs across the refused reconnect.
        clock.advance(by: .seconds(1))
        await first.enqueueFailure(.connectionClosed)

        await waitUntil { await transports.vendedCount == 3 }
        try await driveAuthToReady(connection, third, authSendIndex: 0)
        #expect(await connection.reconnectAttempt == 2)

        // Third socket up well past resetAfter: its drop resets the counter, so
        // the next reconnect starts at attempt 1 rather than 3.
        clock.advance(by: .seconds(120))
        await third.enqueueFailure(.connectionClosed)
        await waitUntil { await transports.vendedCount == 4 }
        #expect(await connection.reconnectAttempt == 1)

        await connection.stop()
    }
}
