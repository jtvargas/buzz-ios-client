import Foundation
@testable import NostrCore
import Testing

/// A scripted network path, so a test drives connectivity transitions instead of the
/// machine's radios.
actor ScriptedPathMonitor: NetworkPathMonitoring {
    private var continuation: AsyncStream<Bool>.Continuation?

    nonisolated func pathAvailability() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        Task { await store(continuation) }
        return stream
    }

    private func store(_ continuation: AsyncStream<Bool>.Continuation) {
        self.continuation = continuation
    }

    /// Reports a path transition, waiting for the connection to have subscribed first
    /// so the yield cannot be dropped on the floor.
    func report(available: Bool) async {
        while continuation == nil {
            await Task.yield()
        }
        continuation?.yield(available)
    }
}

/// Cutting a backoff short when connectivity returns.
///
/// Backoff is the right answer to a relay that is down and the wrong one to a network
/// that was briefly gone: without this, a socket lost in a lift waits out the rest of
/// its schedule — up to 30 s — after the signal is already back.
@Suite("RelayConnection network path")
struct RelayConnectionNetworkPathTests {
    /// A connection whose backoff parks on a gate, so the test decides whether the
    /// schedule or the path transition is what moves it.
    private func makeBackingOffConnection(
        signer: some EventSigner,
        transports: TransportQueue,
        paths: ScriptedPathMonitor,
        backoff: Gate
    ) -> RelayConnection {
        RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            makePathMonitor: { paths },
            backoffSleep: { try await backoff.wait($0) }
        )
    }

    @Test("The network returning reconnects at once instead of waiting out the backoff", .timeLimit(.minutes(1)))
    func pathReturningCutsBackoffShort() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let paths = ScriptedPathMonitor()
        let backoff = Gate()
        let connection = makeBackingOffConnection(
            signer: signer, transports: transports, paths: paths, backoff: backoff
        )

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        // The network goes away: the socket dies and the connection parks on a backoff
        // that nothing but the gate — or the path — can release.
        await paths.report(available: false)
        await connection.handleConnectionLost(generation: connection.currentGeneration)
        await waitForState(connection) { if case .backingOff = $0 { true } else { false } }
        #expect(await transports.vendedCount == 1) // still waiting; the gate is shut

        // Connectivity returns. The backoff is abandoned and a fresh socket opened
        // immediately — the gate is never released, so nothing else could have.
        await paths.report(available: true)
        await waitUntil { await transports.vendedCount == 2 }
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    @Test("A live socket is not disturbed by a path report", .timeLimit(.minutes(1)))
    func liveSocketIgnoresPathReports() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let paths = ScriptedPathMonitor()
        let connection = makeBackingOffConnection(
            signer: signer, transports: transports, paths: paths, backoff: Gate()
        )

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // Switching Wi-Fi networks while the socket is healthy: nothing to accelerate,
        // so nothing is torn down.
        await connection.networkPathBecameAvailable()

        #expect(await connection.state == .ready)
        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }

    @Test("A backgrounded connection stays asleep when the network changes", .timeLimit(.minutes(1)))
    func suspendedConnectionIgnoresPathReports() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let paths = ScriptedPathMonitor()
        let grace = Gate()
        let connection = RelayConnection(
            url: testRelayURL,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            makePathMonitor: { paths },
            backoffSleep: { _ in },
            graceSleep: { try await grace.wait($0) }
        )

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // Backgrounded past the grace window: the socket is deliberately released and
        // must stay released until the app comes back.
        await connection.background()
        await grace.release()
        await waitForState(connection) { $0 == .suspended }

        await connection.networkPathBecameAvailable()

        #expect(await connection.state == .suspended)
        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }

    @Test("A connection stopped for a rejected identity is not revived by the network", .timeLimit(.minutes(1)))
    func authRejectedConnectionIgnoresPathReports() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let paths = ScriptedPathMonitor()
        let connection = makeBackingOffConnection(
            signer: signer, transports: transports, paths: paths, backoff: Gate()
        )

        try await connection.connect()
        await relay.enqueue(Frames.challenge("challenge-1"))
        let authFrame = await relay.awaitSend(index: 0)
        let authID = try authEventID(from: authFrame)
        // A terminal rejection: retrying would hammer the relay forever, and a network
        // transition is not new information about a pubkey the relay refuses.
        await relay.enqueue(Frames.ok(authID, false, "restricted: not a member"))
        await waitForState(connection) { if case .stopped = $0 { true } else { false } }

        await connection.networkPathBecameAvailable()

        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }
}
