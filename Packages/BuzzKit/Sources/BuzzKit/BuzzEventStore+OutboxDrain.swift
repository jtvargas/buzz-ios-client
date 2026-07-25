import Foundation
import GRDB
import NostrCore

/// The drain-side of the outbox: the reads a drain iterates, the stale-timestamp
/// re-sign the relay's ±15-minute ingest gate forces, and the row decode. The
/// enqueue and transition writes live in `BuzzEventStore+Outbox.swift`.
public extension BuzzEventStore {
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

    // MARK: - Reads

    /// The queued send with this id, or `nil` when none is queued.
    func entry(id: String) async throws -> OutboxEntry? {
        try await reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM outbox WHERE event_id = ?", arguments: [id])
                .flatMap(Self.decodeOutbox)
        }
    }

    /// Everything still awaiting delivery, in enqueue order: `pending`, `sending`, and
    /// `awaitingReauth`, but never `failed`.
    ///
    /// **Ordered by `rowid`, not `created_at`.** The drain sends these one at a time,
    /// awaiting each relay verdict before the next, so their order *is* the wire order.
    /// `created_at` is an author-controlled, second-resolution stamp: three sends
    /// composed inside one second tie on it and fall back to `event_id` (a content
    /// hash) — a nondeterministic order. For a reaction lifecycle that is a correctness
    /// bug: a re-react must not overtake its own withdrawal, or the relay dedups the
    /// re-react (OK `duplicate:` → confirmed into the local log) while the withdrawal
    /// then deletes the original relay-side, leaving this device showing a reaction no
    /// other device has. `rowid` is the SQLite insertion order — the true enqueue order
    /// — and the outbox is a rowid table (`Schema`); a re-signed re-queued row lands at
    /// the tail with a fresh row, which is correct (it is a fresh send).
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
        ORDER BY rowid ASC
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

    // MARK: - Row decode

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
}
