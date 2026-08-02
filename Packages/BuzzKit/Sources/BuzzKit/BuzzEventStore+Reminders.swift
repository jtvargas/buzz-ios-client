import Foundation
import GRDB

/// The reminder seam onto the store: applying one decrypted `kind:30300`, and reading the
/// rows back for the Later screen and the notification scheduler.
///
/// Writes go through the actor; reads are `nonisolated` over the concurrent reader so a
/// view model can observe the projection off the actor — the same discipline as
/// ``channelList(selfPubkey:)`` and ``profile(pubkey:)``.
public extension BuzzEventStore {
    /// Applies one decrypted reminder, and reports whether it changed anything.
    ///
    /// Last-writer-wins by `created_at` at the `d` coordinate, which is what "addressable"
    /// means: a relay replaying an older revision after a reconnect must not undo a
    /// completion this device already saw. A tie keeps what is stored — two revisions in
    /// the same second are the same second's truth, and flapping between them would make
    /// the Later screen twitch for no gain.
    @discardableResult
    func applyReminder(_ row: ReminderRow) throws -> Bool {
        try writer.write { db in
            let stored = try Int64.fetchOne(
                db,
                sql: "SELECT created_at FROM reminder WHERE d = ?",
                arguments: [row.id]
            )
            if let stored, stored >= row.createdAt { return false }

            try db.execute(
                sql: """
                INSERT INTO reminder
                    (d, event_id, created_at, not_before, status,
                     target_event_id, target_channel, target_author, preview, note)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(d) DO UPDATE SET
                    event_id        = excluded.event_id,
                    created_at      = excluded.created_at,
                    not_before      = excluded.not_before,
                    status          = excluded.status,
                    target_event_id = excluded.target_event_id,
                    target_channel  = excluded.target_channel,
                    target_author   = excluded.target_author,
                    preview         = excluded.preview,
                    note            = excluded.note
                """,
                arguments: [
                    row.id,
                    row.eventID,
                    row.createdAt,
                    row.notBefore,
                    row.status.rawValue,
                    row.target?.eventID,
                    row.target?.channelID,
                    row.target?.authorPubkey,
                    row.target?.preview,
                    row.note,
                ]
            )
            return true
        }
    }

    /// Every reminder with `status`, newest due first for the pending list and newest
    /// written first for the finished ones.
    ///
    /// Pending orders by `not_before` ascending — the next thing to happen is the thing to
    /// read first. Finished reminders have no due time at all, so they order by when they
    /// were finished.
    nonisolated func reminders(status: ReminderStatus) throws -> [ReminderRow] {
        try reader.read { db in
            let order = status == .pending
                ? "ORDER BY not_before IS NULL, not_before ASC"
                : "ORDER BY created_at DESC"
            return try Row
                .fetchAll(
                    db,
                    sql: "SELECT * FROM reminder WHERE status = ? \(order)",
                    arguments: [status.rawValue]
                )
                .map(Self.makeReminderRow)
        }
    }

    /// One reminder by its `d` tag, for the actions that revise it.
    nonisolated func reminder(id: String) throws -> ReminderRow? {
        try reader.read { db in
            try Row
                .fetchOne(db, sql: "SELECT * FROM reminder WHERE d = ?", arguments: [id])
                .map(Self.makeReminderRow)
        }
    }

    /// How many reminders are still waiting — the number under the Later shortcut card.
    nonisolated func pendingReminderCount() throws -> Int {
        try reader.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM reminder WHERE status = ?",
                arguments: [ReminderStatus.pending.rawValue]
            ) ?? 0
        }
    }

    /// Whether this message already has a reminder waiting on it, so the actions sheet can
    /// say "Reminder set" rather than offering a second one.
    nonisolated func pendingReminder(forEvent eventID: String) throws -> ReminderRow? {
        try reader.read { db in
            try Row
                .fetchOne(
                    db,
                    sql: """
                    SELECT * FROM reminder
                    WHERE status = ? AND target_event_id = ?
                    ORDER BY not_before ASC LIMIT 1
                    """,
                    arguments: [ReminderStatus.pending.rawValue, eventID]
                )
                .map(Self.makeReminderRow)
        }
    }

    private static func makeReminderRow(_ row: Row) -> ReminderRow {
        let target: ReminderTarget? = {
            guard let eventID: String = row["target_event_id"],
                  let channelID: String = row["target_channel"],
                  let authorPubkey: String = row["target_author"]
            else { return nil }
            return ReminderTarget(
                eventID: eventID,
                channelID: channelID,
                preview: row["preview"] ?? "",
                authorPubkey: authorPubkey
            )
        }()

        return ReminderRow(
            id: row["d"],
            eventID: row["event_id"],
            createdAt: row["created_at"],
            notBefore: row["not_before"],
            // A row only reaches the table through ``ReminderContent``'s strict decode, so
            // the stored string is always one of the three. The fallback is for a database
            // hand-edited outside the app, and `cancelled` is the arm that keeps such a row
            // out of the pending list rather than firing a notification for it.
            status: ReminderStatus(rawValue: row["status"]) ?? .cancelled,
            target: target,
            note: row["note"]
        )
    }
}
