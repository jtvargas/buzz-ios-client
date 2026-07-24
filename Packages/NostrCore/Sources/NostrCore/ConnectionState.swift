import Foundation

/// The lifecycle state of a ``RelayConnection``.
///
/// The transitions form a small machine the connection drives and a UI can
/// mirror: `idle → connecting → authenticating → ready`, with a drop routing
/// through `backingOff(attempt:)` back to `connecting`, a backgrounded app
/// resting in `suspended`, and a deliberate or forced end in `stopped`. Every
/// case is distinct on the wire to the UI: "reconnecting" must never be
/// indistinguishable from "healthy", and a terminal auth rejection must be
/// distinguishable from a user-requested stop.
public enum ConnectionState: Sendable, Equatable {
    /// No connection has been attempted, or one was fully torn down and may be
    /// started again.
    case idle
    /// A socket is opening (or reopening) but has not yet authenticated.
    case connecting
    /// The socket is open and a NIP-42 handshake is in flight — a challenge is
    /// being answered, or the relay's verdict on the answer is awaited.
    case authenticating
    /// Authenticated and usable: subscriptions and publishes may proceed.
    case ready
    /// A drop is being retried; `attempt` counts the consecutive reconnect
    /// attempts so the UI can show progress and a test can assert the schedule.
    case backingOff(attempt: Int)
    /// The app backgrounded long enough for the grace window to elapse and the
    /// socket was released. A ``RelayConnection/foreground()`` revives it.
    case suspended
    /// The connection has terminated and will not reconnect on its own.
    case stopped(Termination)

    /// Why a connection reached ``stopped(_:)``.
    public enum Termination: Sendable, Equatable {
        /// The owner called ``RelayConnection/stop()``. A later explicit
        /// ``RelayConnection/connect()`` may start a new connection.
        case client
        /// The relay explicitly rejected this identity (an `OK(false)` on our
        /// NIP-42 auth event whose reason is terminal). Auto-reconnect is
        /// disabled so a rejected pubkey cannot hammer the relay in a loop; the
        /// reason is carried for the UI.
        case authRejected(reason: String)
    }
}
