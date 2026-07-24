import Foundation

/// A relay websocket reduced to the operations the protocol layer needs,
/// expressed as a testability seam.
///
/// # Pull-based by design
///
/// Frames are drawn one at a time with ``receive()`` rather than pushed through
/// a stream. The consumer asks for the next frame only when it is ready to
/// handle one, so *not* calling ``receive()`` is the backpressure: the TCP
/// receive window closes and the relay is throttled by the transport itself.
/// A push/stream model would instead need an unbounded buffer or a drop policy,
/// and this client can least afford to silently drop history mid-backfill.
///
/// # Dumb pipe
///
/// The transport moves opaque text — it does not know what a ``RelayMessage``
/// is. Decoding lives one layer up so the transport stays trivial to fake and
/// impossible to get subtly wrong. Frames go out and come back as `String`
/// because NIP-01 is UTF-8 JSON and some relays reject binary websocket frames.
///
/// # Liveness is the caller's policy, the transport's mechanic
///
/// A half-open socket — the peer gone but the OS not yet aware — makes
/// ``receive()`` hang indefinitely. The transport cannot decide *when* that has
/// become suspicious, but it provides the two mechanics a watchdog needs: the
/// timestamp of the last inbound activity (``lastReceivedAt()`` /
/// ``idleInterval()``) and a ``ping()`` that completes only when the peer
/// answers. The owner (`RelayConnection`) holds the timing policy: when idle
/// past a threshold it races ``ping()`` against a bounded deadline, and a ping
/// that does not return in time is a dead connection.
///
/// Conformance to `Actor` guarantees the serialized access an in-flight
/// ``receive()`` racing a ``close()`` requires, and lets the entire protocol
/// state machine above be tested against a scripted fake with no sockets and no
/// timing flakiness.
public protocol RelayTransport: Actor {
    /// Opens the socket to `url`, returning once it is connected and the peer
    /// has proven responsive. Throws ``TransportError/connectTimeout`` if the
    /// connection neither opens nor fails within the transport's deadline.
    func connect(url: URL) async throws

    /// Sends a text frame. Throws ``TransportError/connectionClosed`` if the
    /// socket is not open.
    func send(_ text: String) async throws

    /// Sends `data` as a text frame — the bytes are UTF-8 JSON on this
    /// protocol, and text is what relays accept.
    func send(_ data: Data) async throws

    /// Returns the next frame, suspending until one arrives. Throws when the
    /// connection closes or the read fails.
    func receive() async throws -> String

    /// Round-trips a websocket ping, returning only once the peer's pong is
    /// received. A ping that never returns is the signal of a dead socket; the
    /// caller enforces the deadline by cancelling this call.
    func ping() async throws

    /// Closes the socket. Any suspended ``receive()`` is unblocked with a
    /// failure. Idempotent.
    func close() async

    /// The instant of the last inbound activity — a received frame or an
    /// answered ping — on the monotonic clock, or `nil` before the first.
    ///
    /// Monotonic (`ContinuousClock`) rather than wall time so the idle interval
    /// a watchdog derives from it is immune to clock adjustments.
    func lastReceivedAt() async -> ContinuousClock.Instant?

    /// How long since the last inbound activity, or `nil` before the first.
    /// A convenience over ``lastReceivedAt()`` that keeps the clock read on the
    /// transport's side of the boundary.
    func idleInterval() async -> Duration?
}
