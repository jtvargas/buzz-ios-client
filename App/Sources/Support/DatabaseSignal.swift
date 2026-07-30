import BuzzKit
import GRDB

/// A change signal over the three tables that back every timeline and channel-list
/// read: the append-only `event` log, the `outbox`, and `read_state`.
///
/// # Why these tables are sufficient
///
/// BuzzKit's storage model makes every mutation that can change a rendered row
/// commit a write to one of these tables inside the *same* transaction:
///
/// - A message, deletion, edit, reaction, profile (kind 0), or channel-metadata
///   (kind 39000) event is itself a row in the append-only `event` log, projected
///   in the same write (see `BuzzEventStore.write`).
/// - An optimistic send, and every delivery-state change (`pending → sending →
///   failed`, or the confirm that deletes the row), is an `outbox` write.
/// - A read-state change — this device marking a channel read, or another device's
///   blob arriving — is a `read_state` write, which moves a channel's unread count.
///
/// So tracking the full-table regions of `event`, `outbox`, and `read_state` re-fires
/// the observation on every change either read would reflect, while the *value* is
/// fetched through BuzzKit's public read API (`channelList()` / `timeline(...)`).
///
/// This is the app-side realisation of the spec's observation pipeline. The
/// ideal shape would be a BuzzKit-provided observation factory (or public
/// `fetch…(Database)` seams) so the app need not name the tracked tables at all;
/// until that lands, this keeps the coupling to a single, documented place. The
/// `channel` doc-comment in `ChannelList.swift` enumerates the same region.
enum DatabaseSignal {
    /// A live async sequence that emits once immediately, then after every
    /// committed transaction that touches `event` or `outbox`. The emitted value
    /// is an opaque token; callers re-read through BuzzKit's public API in
    /// response, they do not consume it.
    static func changes(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                // `event` is append-only: every message, edit, deletion, reaction,
                // profile, or channel change is a *new* row, so row existence
                // (COUNT) captures all of them.
                let events = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0

                // `outbox` rows also change *in place* — `pending → sending →
                // failed`, and a retry back to `pending`. A COUNT would miss those
                // (no row added or removed), so the mutable columns are read
                // explicitly: that both puts them in the tracked region (GRDB
                // re-fires on any write to them) and folds them into the token, so
                // the value itself changes on a state transition.
                var token = events
                let rows = try Row.fetchAll(db, sql: "SELECT event_id, state, last_error FROM outbox")
                for row in rows {
                    let eventID: String = row["event_id"] ?? ""
                    let state: String = row["state"] ?? ""
                    let lastError: String = row["last_error"] ?? ""
                    token = token &+ eventID.hashValue &+ state.hashValue &+ lastError.hashValue
                }

                // `read_state` collapses replaceable per slot, so a mark advances a
                // `read_at` in place rather than adding a row — a COUNT would miss it.
                // Fold each `(context, read_at)` into the token so the channel list's
                // unread counts re-read the instant a frontier moves, from this device
                // or another. Tracking the read means GRDB re-fires on any write to it.
                let frontiers = try Row.fetchAll(db, sql: "SELECT context_id, read_at FROM read_state")
                for row in frontiers {
                    let context: String = row["context_id"] ?? ""
                    let readAt: Int64 = row["read_at"] ?? 0
                    token = token &+ context.hashValue &+ Int(truncatingIfNeeded: readAt)
                }

                // Directory snapshots and accepted lifecycle commands update
                // channel access without necessarily inserting a relay event.
                let accessRows = try Row.fetchAll(
                    db,
                    sql: "SELECT identity_pubkey, channel_id, state, updated_at FROM channel_access"
                )
                for row in accessRows {
                    let identity: String = row["identity_pubkey"] ?? ""
                    let channel: String = row["channel_id"] ?? ""
                    let state: String = row["state"] ?? ""
                    let updatedAt: Int64 = row["updated_at"] ?? 0
                    token = token
                        &+ identity.hashValue
                        &+ channel.hashValue
                        &+ state.hashValue
                        &+ Int(truncatingIfNeeded: updatedAt)
                }
                return token
            }
            .values(in: reader)
    }
}
