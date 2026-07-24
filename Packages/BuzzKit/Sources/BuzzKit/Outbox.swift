import Foundation
import NostrCore

/// The lifecycle of a message this client sent.
///
/// A send is a small state machine kept in the `outbox` table. It exists there
/// only until the relay acknowledges it, at which point ``BuzzEventStore/confirmSent(_:)``
/// moves it into the append-only log in one transaction — the id it was signed
/// with is the id it lands under, so the UI animates a message from pending to
/// sent instead of swapping one row for another.
///
/// There is deliberately no `sent` case: "sent" is not an outbox state, it is the
/// absence of an outbox row and the presence of a log row.
public enum OutboxState: String, Sendable, Equatable, CaseIterable {
    /// Signed and queued, not yet handed to the relay. Also the state a send
    /// returns to after a transient (`retryable`) rejection, so the next drain
    /// picks it up again.
    case pending
    /// Handed to the relay, awaiting its `OK`. A row found here at drain time is
    /// resent as-is: the outcome is unknown, and the relay deduplicates by event
    /// id, so a resend either lands or comes back `duplicate:` — both success.
    case sending
    /// The relay refused it terminally, or its retry budget was exhausted. Not
    /// resent automatically; it waits for an explicit user retry.
    case failed
    /// The relay demanded a completed NIP-42 handshake first. The connection layer
    /// re-authenticates; the outbox records the wait so the intent survives a
    /// restart, and the engine resends once auth completes.
    case awaitingReauth
}

/// A queued send, carrying the signed event plus the denormalized fields the
/// timeline reads without decoding the payload JSON.
public struct OutboxEntry: Sendable, Equatable, Identifiable {
    /// The signed event. Its `id` is the outbox row's primary key and the id the
    /// event will carry in the log once confirmed.
    public let event: NostrEvent
    /// The channel this send belongs to, denormalized for the outbox index and the
    /// timeline union.
    public let channelID: String
    public let state: OutboxState
    /// How many times this send has been handed to the relay. Drives the retry cap.
    public let attempts: Int
    /// The last relay reason or failure, kept to surface on a `failed` send.
    public let lastError: String?

    public var id: String { event.id }

    public init(
        event: NostrEvent,
        channelID: String,
        state: OutboxState,
        attempts: Int,
        lastError: String?
    ) {
        self.event = event
        self.channelID = channelID
        self.state = state
        self.attempts = attempts
        self.lastError = lastError
    }
}

/// What the store decided a relay rejection means for a queued send.
///
/// The store performs the resulting state change and returns the outcome; the
/// engine drives the timing (when to redrain, when to re-authenticate, when to
/// resend the re-signed event). Keeping the classification here means one policy
/// serves the engine rather than the engine re-deriving it from `OKReason`.
public enum OutboxResolution: Sendable, Equatable {
    /// The relay already had the event (`duplicate:`) or accepted it; it was moved
    /// into the log.
    case confirmed
    /// Terminally rejected. The row is now ``OutboxState/failed`` carrying the
    /// reason.
    case failed(String)
    /// The relay wants NIP-42 auth first. The row is ``OutboxState/awaitingReauth``.
    case awaitingReauth
    /// Transient rejection under the retry budget. The row is back to
    /// ``OutboxState/pending`` for the next drain; the value is the attempt count
    /// so far.
    case retrying(attempts: Int)
    /// Transient rejection that exhausted the retry budget. The row is now
    /// ``OutboxState/failed``.
    case exhausted(String)
    /// A stale-timestamp rejection: the send was re-signed with a fresh
    /// `created_at` under a new id and requeued as ``OutboxState/pending``. The
    /// value is the new event id the engine should now send.
    case resigned(newID: String)
}

/// Tunable limits for the outbox, defaulted from the relay facts the spec pins.
public enum OutboxPolicy {
    /// The client-side content ceiling in UTF-8 bytes. The relay advertises
    /// `max_content_len` in NIP-11 (64 KiB) and hard-caps ingest at 256 KiB;
    /// 64 KiB is the correct send ceiling, read from NIP-11 when known and this
    /// value otherwise. Oversized content is a caller error, never truncated.
    public static let maxContentBytes = 65_536

    /// How old a queued send may be before its `created_at` must be refreshed.
    /// The relay rejects any event whose timestamp is more than 15 minutes from
    /// server time; re-signing at 10 leaves margin for the round trip.
    public static let staleAfter: TimeInterval = 600

    /// How many times a send may be handed to the relay before a transient
    /// rejection is treated as terminal.
    public static let maxAttempts = 5
}

/// Errors raised by the outbox, distinct from the GRDB and codec errors that
/// surface as thrown `DatabaseError`/`DecodingError`.
public enum OutboxError: Error, Equatable {
    /// The content exceeded the send ceiling. Carries the size seen and the limit
    /// so the caller can tell the user by how much, rather than silently truncating
    /// a message they believe they sent whole.
    case contentTooLarge(bytes: Int, limit: Int)
    /// A queued event failed verification on confirmation, which would mean it was
    /// altered between signing and acknowledgement. The confirm path is the same
    /// choke point as ingest; there is no unverified route into the log.
    case invalidEvent(String)
    /// An operation referenced an event id that is not in the outbox.
    case notQueued(String)
    /// Encoding a queued event to JSON produced non-UTF-8 bytes. Unreachable in
    /// practice — `JSONEncoder` always emits UTF-8 — but surfaced as an honest
    /// failure path rather than force-unwrapped.
    case encodingFailed
}
