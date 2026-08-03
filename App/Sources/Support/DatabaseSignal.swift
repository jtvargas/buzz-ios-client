import BuzzKit
import GRDB

/// A change signal over the tables that back every timeline and channel-list read:
/// the append-only `event` log, the `outbox`, `read_state`, `thread_fetch`, and
/// `channel_access`.
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
/// - The relay's reply tally for a message (kind 39005) is itself a logged event, so
///   a badge moving because the relay said so is already covered by `event`. The
///   *other* half of that tally is not: `thread_fetch` records this device holding a
///   thread in full, and one such write has no event behind it at all.
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
        tracked.values(in: reader)
    }

    /// The same signal, keeping only the **newest** pending token instead of every one.
    ///
    /// For a consumer whose read is expensive enough that it wants to coalesce a burst
    /// rather than serve each commit in it. `values(in:)` defaults to
    /// `.unbounded` (`GRDB/ValueObservation/ValueObservation.swift:353`), which means a slow
    /// consumer does not shed load — it queues, and then works through every intermediate
    /// token after the fact. Sleeping inside such a loop delays the work without reducing
    /// it, which is the trap this exists to avoid.
    ///
    /// With `.bufferingNewest(1)`, everything that lands while the consumer is busy or
    /// waiting collapses into one token. Pair it with a wait after each read — the wait is
    /// what creates the window for the collapse; the policy is what makes the collapse
    /// happen instead of a queue.
    ///
    /// **Deliberately not the default.** The timeline reads this same signal
    /// (``ChannelTimelineModel+Live``), and an optimistic send is an `outbox` write inside
    /// the tracked region — so coalescing globally would put a delay between pressing send
    /// and seeing your own message, which is the one latency in a chat app anybody notices.
    /// Surfaces that summarise (``ActivityModel``) can afford it; surfaces you are typing
    /// into cannot.
    static func coalescedChanges(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        tracked.values(in: reader, bufferingPolicy: .bufferingNewest(1))
    }

    /// The tracked region, shared by both entry points so they cannot drift.
    private static var tracked: ValueObservation<ValueReducers.Fetch<Int>> {
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

                // A thread fetch is this device recording that it now holds a thread in
                // full, which changes that message's reply tally (see
                // `BuzzEventStore.recordThreadFetch`) — and it is the one such change
                // that can happen with **no event row behind it**: opening a thread
                // whose replies were all withdrawn ingests nothing, so `COUNT(*) FROM
                // event` does not move and the badge would keep advertising replies
                // that are not there until some unrelated event happened along. Both
                // columns, because a second fetch of the same root updates the row in
                // place rather than adding one.
                let fetches = try Row.fetchAll(db, sql: "SELECT root_id, summary_event_id FROM thread_fetch")
                for row in fetches {
                    let root: String = row["root_id"] ?? ""
                    let summary: String = row["summary_event_id"] ?? ""
                    token = token &+ root.hashValue &+ summary.hashValue
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
    }

    /// A change signal over `composer_draft` alone.
    ///
    /// Deliberately **not** folded into ``changes(in:)``, and this is the load-bearing part:
    /// that region is tracked by every timeline, the sidebar and the Threads screen, and a
    /// draft is written on essentially every keystroke. Putting the table in there would
    /// make typing one word re-read every conversation list in the app.
    ///
    /// Emits on any write to the table — including a draft's text changing, which no caller
    /// of this is currently interested in. That is the honest region to track for a list of
    /// drafts, and the surfaces that read it (a pushed screen, and a count that
    /// ``draftCount(in:)`` de-duplicates) are the only ones awake for it.
    static func composerDrafts(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                var token = 0
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT channel_id, root_id, updated_at FROM composer_draft"
                )
                for row in rows {
                    let channel: String = row["channel_id"] ?? ""
                    let root: String = row["root_id"] ?? ""
                    let updatedAt: Int64 = row["updated_at"] ?? 0
                    token = token
                        &+ channel.hashValue
                        &+ root.hashValue
                        &+ Int(truncatingIfNeeded: updatedAt)
                }
                return token
            }
            .values(in: reader)
    }

    /// How many composers hold unsent text, emitted only when the number actually changes.
    ///
    /// `removeDuplicates` is what makes this safe to run behind the sidebar for the life of
    /// the session: the underlying table is written on every keystroke, and without it the
    /// shortcut card would be invalidated at typing speed to be told the same number.
    static func draftCount(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        ValueObservation
            .tracking { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM composer_draft") ?? 0
            }
            .removeDuplicates()
            .values(in: reader)
    }
}
