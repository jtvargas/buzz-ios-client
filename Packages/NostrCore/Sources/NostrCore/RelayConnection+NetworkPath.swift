import Foundation

/// Watching for the network to come back, so a backoff is cut short by a fact rather
/// than waited out.
extension RelayConnection {
    /// Begins watching network availability, once per connection. Idempotent, so the
    /// repeated ``connect()`` a reconnect or a re-login makes does not stack observers.
    func startPathMonitoring() {
        guard pathMonitorTask == nil else { return }
        let availability = makePathMonitor().pathAvailability()
        pathMonitorTask = Task { [weak self] in
            for await isAvailable in availability where isAvailable {
                await self?.networkPathBecameAvailable()
            }
        }
    }

    /// The network came back. Cuts a backoff short rather than waiting it out.
    ///
    /// Only a connection actually *waiting* — ``ConnectionState/backingOff`` — is
    /// touched. A live socket needs nothing, a suspended one is a backgrounded app that
    /// must stay asleep (``reconnectSuppressed`` covers it), and a handshake in flight
    /// has its own deadline.
    ///
    /// The attempt counter is deliberately **not** reset, unlike in ``foreground()``. A
    /// person opening the app is a reason to start the schedule over; a path flipping is
    /// not, and a flapping network that reset it on every flip would hammer the relay
    /// with exactly the unbackoffed retries ``ReconnectPolicy`` exists to prevent. So
    /// this skips the current wait and leaves the schedule where it was.
    ///
    /// Internal so a test can pose the transition directly.
    func networkPathBecameAvailable() async {
        guard !isStopping, !authTerminated, !reconnectSuppressed else { return }
        guard case .backingOff = state else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in await self?.reconnectImmediately() }
    }
}
