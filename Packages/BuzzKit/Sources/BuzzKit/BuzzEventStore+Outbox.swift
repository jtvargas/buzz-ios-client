import Foundation
import GRDB
import NostrCore

/// The write-side of the outbox lifecycle: enqueue, the state transitions, and the
/// relay-verdict policy. The drain-side reads and the stale-timestamp re-sign live
/// in `BuzzEventStore+OutboxDrain.swift`.
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
    ///   - createdAt: an explicit signing timestamp, defaulting to the store clock.
    ///     Read-state sends pass one strictly newer than their slot's last blob so
    ///     the addressable replace never ties on `created_at` (NIP-RS clock skew);
    ///     ordinary sends leave it `nil` and take the wall clock.
    /// - Returns: the queued entry.
    @discardableResult
    func enqueue(
        kind: EventKind = .channelMessage,
        content: String,
        in channel: String,
        tags: [[String]] = [],
        with signer: any EventSigner,
        maxContentBytes: Int = OutboxPolicy.maxContentBytes,
        createdAt: Date? = nil
    ) async throws -> OutboxEntry {
        let byteCount = content.utf8.count
        guard byteCount <= maxContentBytes else {
            throw OutboxError.contentTooLarge(bytes: byteCount, limit: maxContentBytes)
        }

        let event = try await signer.sign(kind: kind, content: content, tags: tags, createdAt: createdAt ?? clock())
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
    ///
    /// The gate is the store's own `verify` — the identical id-then-signature check
    /// the ingest choke point runs — not `isValid` alone, so the confirm path admits
    /// exactly what ingest would and no more.
    func confirmSent(_ event: NostrEvent) async throws {
        guard case .valid = Self.verify(event) else { throw OutboxError.invalidEvent(event.id) }
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
    func markFailed(_ eventID: String, error: String?, retryable: Bool = true) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE outbox SET state = ?, last_error = ?, is_retryable = ? WHERE event_id = ?",
                arguments: [OutboxState.failed.rawValue, error, retryable, eventID]
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
            guard let retryable = try Bool.fetchOne(
                db,
                sql: "SELECT is_retryable FROM outbox WHERE event_id = ?",
                arguments: [eventID]
            ) else {
                throw OutboxError.notQueued(eventID)
            }
            guard retryable else { throw OutboxError.notRetryable(eventID) }
            try db.execute(
                sql: """
                UPDATE outbox
                   SET state = ?, attempts = 0, last_error = NULL
                 WHERE event_id = ?
                """,
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
            try await markFailed(eventID, error: detail, retryable: false)
            return .failed(detail)

        case .reauthThenRetry:
            try await markAwaitingReauth(eventID)
            return .awaitingReauth

        case .retryable:
            if entry.attempts >= maxAttempts {
                try await markFailed(eventID, error: detail, retryable: true)
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

    // MARK: - Row insertion

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
                 state, attempts, root_id, parent_id, tags, kind)
            VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
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
                // Denormalized so the message unions can exclude a queued reaction or
                // withdrawal without decoding `payload`; the drain still sends every
                // kind, so a reaction is delivered durably like any other send.
                event.kind.rawValue,
            ]
        )
    }

    /// Encodes a value to a UTF-8 JSON string. `JSONEncoder` always emits UTF-8, so
    /// the failing branch is unreachable; it throws rather than force-unwrapping.
    private static func json(_ value: some Encodable) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let string = String(bytes: data, encoding: .utf8) else {
            throw OutboxError.encodingFailed
        }
        return string
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
