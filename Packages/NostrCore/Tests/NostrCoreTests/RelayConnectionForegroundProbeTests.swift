import Foundation
@testable import NostrCore
import Testing

/// The foreground liveness probe: a `.ready` socket that outlived a background
/// freeze is proven with a bounded ping before it is trusted, because the frozen
/// process cannot notice a silently-dropped TCP and the idle watchdog would take
/// tens of seconds to. A failed probe reconnects at once (fresh `.ready`, which
/// drives the sync engine's catch-up); a passing probe keeps the socket, no churn.
@Suite("RelayConnection foreground liveness probe")
struct RelayConnectionForegroundProbeTests {
    @Test("Foreground on a dead socket probes, fails, and reconnects", .timeLimit(.minutes(1)))
    func foregroundProbesDeadSocketAndReconnects() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        // The freeze killed the TCP but the socket still reports ready: model that
        // as a peer that can no longer answer a ping.
        await first.failPings(with: .connectionClosed)
        await connection.foreground()

        // The probe fails, tears the dead socket down, and reconnects immediately —
        // a second transport is vended and drives a fresh handshake to ready.
        await waitUntil { await transports.vendedCount == 2 }
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    @Test("Foregrounding a live socket probes, succeeds, and keeps the connection", .timeLimit(.minutes(1)))
    func foregroundProbeKeepsLiveSocket() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let pingsBefore = await relay.pingCount
        await connection.foreground() // state is .ready → the probe pings the live socket

        // The probe actually pinged (proving it ran), the socket answered, and the
        // connection was kept: no reconnect, no second transport, still ready.
        await waitUntil { await relay.pingCount == pingsBefore + 1 }
        #expect(await connection.state == .ready)
        #expect(await transports.vendedCount == 1)

        await connection.stop()
    }
}
