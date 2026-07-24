import Foundation

/// Why a ``RelayConnection`` operation failed.
///
/// These are the protocol- and lifecycle-level failures a caller of `publish` or
/// `query` faces, one layer above the pipe-level ``TransportError``. A rejection
/// the relay stated (`OK(false)`, `CLOSED`) is carried as a typed ``OKReason`` so
/// the caller — and the Phase 2 outbox — can decide retry from the classification
/// rather than re-parsing a string.
public enum RelayConnectionError: Error, Equatable, Sendable {
    /// There is no live, authenticated connection to carry the request, and one
    /// is not expected imminently.
    case notConnected
    /// The connection was stopped by its owner while the request was in flight or
    /// waiting.
    case stopped
    /// The socket dropped while the request was in flight. In-flight publishes
    /// and one-shot queries fail with this rather than hanging; the caller owns
    /// the retry (the outbox for publishes, a fresh query for reads).
    case connectionLost
    /// A NIP-42 handshake did not complete — the signer failed, or the relay
    /// rejected the answer for a reason that is not terminal (so a reconnect may
    /// still succeed).
    case authenticationFailed(String)
    /// The relay explicitly rejected this identity with a terminal reason. The
    /// connection stops and does not auto-reconnect; retrying the same pubkey
    /// would only hammer the relay.
    case authenticationRejected(String)
    /// A publish was refused, carrying the relay's classified reason.
    case publishRejected(OKReason)
    /// A publish for this event id is already awaiting its `OK`. Overwriting the
    /// pending continuation would strand the first caller forever, so the second
    /// call is refused instead; the outbox retries after the first resolves.
    case duplicatePublish
    /// A subscription was closed by the relay for a reason that is not retryable
    /// under NIP-42 (e.g. `restricted:`), carrying the classified reason.
    case subscriptionClosed(OKReason)
    /// A bounded wait — for authentication, or for a one-shot query's EOSE —
    /// expired.
    case timedOut
}
