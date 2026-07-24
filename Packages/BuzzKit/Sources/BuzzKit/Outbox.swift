import Foundation
import GRDB
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
}

public extension BuzzEventStore {
    // MARK: - Enqueue

    /// Signs a message and queues it for sending, in one operation.
    ///
    /// The event id is a hash of the message's own fields, so it exists the moment
    /// the message is signed — before the relay is ever contacted. That is what
    /// lets the queued row and the eventual log row share an identity: the timeline
    /// renders the pending send optimistically and, on confirmation, the same row
    /// simply changes state.
    ///
    /// The content ceiling is enforced here, before signing, because an oversized
    /// message is a caller error the relay would reject outright — surfacing it at
    /// the door is honest, where truncating it to fit would silently corrupt a
    /// message the user believes they sent in full.
    ///
    /// - Parameters:
    ///   - kind: the event kind; defaults to a channel message.
    ///   - content: the message body. Rejected if it exceeds `maxContentBytes`.
    ///   - channel: the channel id, denormalized onto the row. The caller is
    ///     responsible for including any scope tag (e.g. `h`) in `tags`; enqueue
    ///     signs the fields it is given rather than imposing a message shape.
    ///   - tags: the event tags, including thread markers if this is a reply.
    ///   - signer: the identity to sign with.
    ///   - maxContentBytes: the send ceiling, from NIP-11 when known.
    /// - Returns: the queued entry.
    @discardableResult
    func enqueue(
        kind: EventKind = .channelMessage,
        content: String,
        in channel: String,
        tags: [[String]] = [],
        with signer: any EventSigner,
        maxContentBytes: Int = OutboxPolicy.maxContentBytes
    ) async throws -> OutboxEntry {
        let byteCount = content.utf8.count
        guard byteCount <= maxContentBytes else {
            throw OutboxError.contentTooLarge(bytes: byteCount, limit: maxContentBytes)
        }

        let event = try await signer.sign(kind: kind, content: content, tags: tags, createdAt: clock())
        try await writer.write { db in
            try Self.insertOutboxRow(event, channel: channel, state: .pending, into: db)
        }
        return OutboxEntry(event: event, channelID: channel, state: .pending, attempts: 0, lastError: nil)
    }

    // MARK: - Transitions

    /// Marks a queued send as handed to the relay, counting the attempt.
    ///
    /// The attempt count is the retry budget's odometer: it advances on each send,
    /// so a transient failure can be retried under a cap without the outbox
    /// remembering anything more than a number.
    func markSending(_ eventID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, attempts = attempts + 1 WHERE event_id = ?",
                arguments: [OutboxState.sending.rawValue, eventID]
            )
        }
    }

    /// Records that the relay accepted a queued send, moving it into the log and
    /// dropping the queue row in one transaction.
    ///
    /// The single transaction is the whole point: the timeline can never observe
    /// the message as both pending and sent, or as neither. The event goes through
    /// ``BuzzEventStore/write(_:receivedAt:projector:into:)`` — the same verified
    /// route as anything off the wire. Trusting it because we signed it would open
    /// a second, unverified path into the log, and the value of a single choke
    /// point is that it has no exceptions. If a relay echo already delivered the
    /// event, that write is a no-op and only the queue row is cleared.
    func confirmSent(_ event: NostrEvent) async throws {
        guard event.isValid else { throw OutboxError.invalidEvent(event.id) }
        let receivedAt = Int64(clock().timeIntervalSince1970)
        let projector = projector
        try await writer.write { db in
            _ = try Self.write(event, receivedAt: receivedAt, projector: projector, into: db)
            try db.execute(sql: "DELETE FROM outbox WHERE event_id = ?", arguments: [event.id])
        }
    }

    /// Records a terminal rejection or send failure, with a reason to show the
    /// user. The row stays in the outbox as ``OutboxState/failed`` so the message
    /// is not lost; it simply stops being resent automatically.
    func markFailed(_ eventID: String, error: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ? WHERE event_id = ?",
                arguments: [OutboxState.failed.rawValue, error, eventID]
            )
        }
    }

    /// Records that the relay wants a NIP-42 handshake first. The connection layer
    /// performs the re-auth; this only marks the wait so it survives a restart.
    func markAwaitingReauth(_ eventID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ? WHERE event_id = ?",
                arguments: [OutboxState.awaitingReauth.rawValue, eventID]
            )
        }
    }

    /// Drops a queued send without delivering it — a user-cancelled retry.
    func discard(_ eventID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE event_id = ?", arguments: [eventID])
        }
    }

    /// Returns a `failed` send to `pending` for an explicit user retry, resetting
    /// its attempt budget: a deliberate human retry is a fresh start, not a
    /// continuation of the automated backoff that gave up.
    func retry(_ eventID: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, attempts = 0, last_error = NULL WHERE event_id = ?",
                arguments: [OutboxState.pending.rawValue, eventID]
            )
        }
    }

    // MARK: - Relay verdict

    /// Applies a relay rejection to a queued send and records the resulting state.
    ///
    /// This is the disposition policy in one place. Each `OKReason` maps to one of
    /// four actions via ``OKReason/Disposition``, with one refinement the relay's
    /// ±15-minute ingest gate forces: an `invalid:` on a send older than the stale
    /// threshold is not terminal but timestamp-stale, and is re-signed rather than
    /// failed. The trigger is the *classification plus local age*, never the reason
    /// text — had the relay stored the original event, its answer would have been
    /// `duplicate:`, so an `invalid:` on an aged send can only be the timestamp
    /// window closing.
    ///
    /// An `OK(true)` acceptance is not a rejection and carries no `OKReason`; the
    /// engine confirms those directly through ``confirmSent(_:)``.
    ///
    /// - Parameters:
    ///   - reason: the classified relay rejection.
    ///   - eventID: the send the verdict is about.
    ///   - signer: the identity, needed to re-sign a timestamp-stale send.
    ///   - maxAttempts: the retry cap for transient rejections.
    ///   - staleAfter: the age past which an `invalid:` is treated as timestamp-stale.
    @discardableResult
    func resolve(
        _ reason: OKReason,
        for eventID: String,
        with signer: any EventSigner,
        maxAttempts: Int = OutboxPolicy.maxAttempts,
        staleAfter: TimeInterval = OutboxPolicy.staleAfter
    ) async throws -> OutboxResolution {
        guard let entry = try await entry(id: eventID) else {
            throw OutboxError.notQueued(eventID)
        }
        let detail = reason.detail

        switch reason.disposition {
        case .alreadyAccepted:
            try await confirmSent(entry.event)
            return .confirmed

        case .terminal:
            if reason.isInvalid, isStale(entry, staleAfter: staleAfter) {
                let resigned = try await reSign(entry, with: signer)
                return .resigned(newID: resigned.id)
            }
            try await markFailed(eventID, error: detail)
            return .failed(detail)

        case .reauthThenRetry:
            try await markAwaitingReauth(eventID)
            return .awaitingReauth

        case .retryable:
            if entry.attempts >= maxAttempts {
                try await markFailed(eventID, error: detail)
                return .exhausted(detail)
            }
            try await writer.write { db in
                try db.execute(
                    sql: "UPDATE outbox SET state = ?, last_error = ? WHERE event_id = ?",
                    arguments: [OutboxState.pending.rawValue, detail, eventID]
                )
            }
            return .retrying(attempts: entry.attempts)
        }
    }

    // MARK: - Stale-timestamp re-sign

    /// Whether a queued send is old enough that the relay's ±15-minute ingest gate
    /// would reject its original timestamp, so it must be re-signed before sending.
    func isStale(_ entry: OutboxEntry, staleAfter: TimeInterval = OutboxPolicy.staleAfter) -> Bool {
        clock().timeIntervalSince1970 - Double(entry.event.createdAt) > staleAfter
    }

    /// Re-signs a queued send with a fresh `created_at` and swaps its identity in
    /// one transaction: the old row is deleted and a new `pending` row inserted
    /// under the new event id.
    ///
    /// This is what keeps a message composed offline from being lost. Re-signing
    /// mints a new id (the id is a hash over `created_at` among other fields), and
    /// the swap is safe precisely because the relay never saw the old id — had it,
    /// the answer would have been `duplicate:`, not the `invalid:` that sent us
    /// here. The new send inherits the message's kind, content, and tags unchanged,
    /// so its thread position and channel scope are preserved; only the timestamp,
    /// id, and signature move. The fresh timestamp is also self-limiting: a second
    /// `invalid:` on the re-signed send would find it no longer stale, so it fails
    /// rather than re-signing forever.
    @discardableResult
    func reSign(_ eventID: String, with signer: any EventSigner) async throws -> OutboxEntry {
        guard let entry = try await entry(id: eventID) else {
            throw OutboxError.notQueued(eventID)
        }
        return try await reSign(entry, with: signer)
    }

    // MARK: - Reads

    /// The queued send with this id, or `nil` when none is queued.
    func entry(id: String) async throws -> OutboxEntry? {
        try await reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE event_id = ?", arguments: [id])
                .flatMap(Self.decodeOutbox)
        }
    }

    /// Everything still awaiting delivery, oldest first: `pending`, `sending`, and
    /// `awaitingReauth`, but never `failed`.
    ///
    /// `sending` rows are included on purpose. That state means the app stopped
    /// between handing a send to the relay and hearing back, so the outcome is
    /// unknown; resending is safe because the relay deduplicates by event id,
    /// whereas dropping it would silently lose a message the user believes they
    /// sent. `failed` rows are excluded: they are surfaced for an explicit retry,
    /// not resent under the drain.
    func pendingSends(channel: String? = nil) async throws -> [OutboxEntry] {
        let channelFilter = channel == nil ? "" : "AND channel_id = :channel"
        let sql = """
        SELECT * FROM outbox
        WHERE state <> :failed \(channelFilter)
        ORDER BY created_at ASC, event_id ASC
        """
        return try await reader.read { db in
            try Row.fetchAll(
                db,
                sql: sql,
                arguments: ["failed": OutboxState.failed.rawValue, "channel": channel]
            ).compactMap(Self.decodeOutbox)
        }
    }

    /// The sends that gave up — terminal rejections and exhausted retries — for the
    /// UI to surface with a retry affordance. Oldest first.
    func failedSends(channel: String? = nil) async throws -> [OutboxEntry] {
        let channelFilter = channel == nil ? "" : "AND channel_id = :channel"
        let sql = """
        SELECT * FROM outbox
        WHERE state = :failed \(channelFilter)
        ORDER BY created_at ASC, event_id ASC
        """
        return try await reader.read { db in
            try Row.fetchAll(
                db,
                sql: sql,
                arguments: ["failed": OutboxState.failed.rawValue, "channel": channel]
            ).compactMap(Self.decodeOutbox)
        }
    }

    /// The number of rows currently in the outbox, across all states.
    func outboxCount() async throws -> Int {
        try await reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM outbox") ?? 0
        }
    }

    // MARK: - Internal

    /// Re-signs an already-read entry. Split from the public `reSign(_:with:)` so
    /// `resolve` reuses the row it already holds rather than reading it twice.
    internal func reSign(_ entry: OutboxEntry, with signer: any EventSigner) async throws -> OutboxEntry {
        let fresh = try await signer.sign(
            kind: entry.event.kind,
            content: entry.event.content,
            tags: entry.event.tags,
            createdAt: clock()
        )
        let channel = entry.channelID
        let oldID = entry.event.id
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM outbox WHERE event_id = ?", arguments: [oldID])
            try Self.insertOutboxRow(fresh, channel: channel, state: .pending, into: db)
        }
        return OutboxEntry(event: fresh, channelID: channel, state: .pending, attempts: 0, lastError: nil)
    }

    /// Inserts an outbox row for a signed event. Static so it runs inside a caller's
    /// write transaction — the enqueue write and, crucially, the re-sign's atomic
    /// delete-then-insert both flow through it.
    ///
    /// Thread position and channel scope are denormalized out of the event's tags
    /// so a queued reply renders in its thread immediately, and the whole signed
    /// event is stored as `payload` so a resend or a re-sign can reconstruct it
    /// without the log. `ON CONFLICT DO NOTHING` makes an echoed enqueue a no-op.
    internal static func insertOutboxRow(
        _ event: NostrEvent,
        channel: String,
        state: OutboxState,
        into db: Database
    ) throws {
        let reference = event.threadReference
        try db.execute(
            sql: """
            INSERT INTO outbox
                (event_id, channel_id, pubkey, content, created_at, payload,
                 state, attempts, root_id, parent_id, tags)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
            ON CONFLICT(event_id) DO NOTHING
            """,
            arguments: [
                event.id,
                channel,
                event.pubkey,
                event.content,
                event.createdAt,
                try Self.json(event),
                state.rawValue,
                reference.rootID,
                reference.parentID,
                try Self.json(event.tags),
            ]
        )
    }

    /// Reconstructs a queued entry from its row, or `nil` when its payload cannot be
    /// decoded — a corrupt row is treated as absent rather than crashing a drain.
    internal static func decodeOutbox(_ row: Row) -> OutboxEntry? {
        let payload: String = row["payload"]
        guard let event = try? JSONDecoder().decode(NostrEvent.self, from: Data(payload.utf8)) else {
            return nil
        }
        return OutboxEntry(
            event: event,
            channelID: row["channel_id"],
            state: OutboxState(rawValue: row["state"]) ?? .pending,
            attempts: row["attempts"],
            lastError: row["last_error"]
        )
    }

    /// Encodes a value to a UTF-8 JSON string. `JSONEncoder` always emits UTF-8, so
    /// the decoding is total.
    private static func json(_ value: some Encodable) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }
}

// MARK: - OKReason helpers

private extension OKReason {
    /// The human-readable remainder the relay attached, for surfacing on a failed
    /// send.
    var detail: String {
        switch self {
        case let .duplicate(message),
             let .pow(message),
             let .rateLimited(message),
             let .invalid(message),
             let .restricted(message),
             let .authRequired(message),
             let .blocked(message),
             let .error(message),
             let .unspecified(message):
            message
        }
    }

    /// Whether this is an `invalid:` rejection — the classification (not the text)
    /// that, combined with local age, triggers a timestamp re-sign.
    var isInvalid: Bool {
        if case .invalid = self { true } else { false }
    }
}
