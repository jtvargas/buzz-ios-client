import Foundation
import Network

/// Whether the device currently has a usable network path.
///
/// # Why the connection watches this at all
///
/// Backoff is the right answer to a relay that is down and the wrong answer to a
/// network that was briefly gone. Without this, a client that lost its socket in a
/// lift, on a plane, or in the second between Wi-Fi and cellular sits out the rest of
/// its backoff — up to ``ReconnectPolicy/cap`` — after connectivity is already back,
/// with nothing on screen to explain the wait. The path is the one signal that says
/// "try now" with real information behind it, rather than guessing with a timer.
///
/// A protocol rather than a bare `NWPathMonitor` for the reason every other
/// collaborator here is injected: a test drives the transitions by hand instead of
/// waiting on the machine's actual radios.
public protocol NetworkPathMonitoring: Sendable {
    /// A live feed of path availability: `true` while a usable path exists, `false`
    /// while none does. The first element is the current value.
    func pathAvailability() -> AsyncStream<Bool>
}

/// The production monitor, backed by `Network`'s `NWPathMonitor`.
///
/// The monitor is created per stream and cancelled when the stream terminates, so a
/// connection that stops — or a consumer task that is cancelled — takes its system
/// resources with it rather than leaving a path observer running for the life of the
/// process.
public struct SystemNetworkPathMonitor: NetworkPathMonitoring {
    public init() {}

    public func pathAvailability() -> AsyncStream<Bool> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                continuation.yield(path.status == .satisfied)
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "com.hive.nostrcore.path-monitor"))
        }
    }
}
