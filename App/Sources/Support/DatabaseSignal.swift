import BuzzKit
import GRDB

/// A change signal over the tables that back every timeline and channel-list read:
/// the append-only `event` log, the `outbox`, `read_state`, `thread_fetch`, and
/// `channel_access`.
///
/// # Why these tables are sufficient
///
/// BuzzKit's storage model makes every mutation that can change a rendered row commit
/// a write to one of these tables inside the *same* transaction — ``trackedTables``
/// names each one and what reaches it. So tracking their full-table regions re-fires
/// the observation on every change either read would reflect, while the *value* is
/// fetched through BuzzKit's public read API (`channelList()` / `timeline(...)`).
///
/// This is the app-side realisation of the spec's observation pipeline. The
/// ideal shape would be a BuzzKit-provided observation factory (or public
/// `fetch…(Database)` seams) so the app need not name the tracked tables at all;
/// until that lands, this keeps the coupling to a single, documented place. The
/// `channel` doc-comment in `ChannelList.swift` enumerates the same region.
enum DatabaseSignal {
    /// A live async sequence that emits once immediately, then after every committed
    /// transaction that touches any of ``trackedTables``. The emitted value is an opaque
    /// token; callers re-read through BuzzKit's public API in response, they do not
    /// consume it.
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
    ///
    /// # Why the region is declared constant
    ///
    /// It is one: the same six tables are read unconditionally on every pass, so no
    /// commit can move the observation onto a table it was not already watching. Saying
    /// so out loud is not a formality. GRDB cannot fetch a *non*-constant region
    /// concurrently — a change landing in the region the next fetch is about to adopt
    /// would go unnoticed, because nothing knew that region was coming — and it resolves
    /// that the only way it safely can: by fetching **on the write connection**, inline
    /// in `databaseDidCommit`
    /// (`GRDB/ValueObservation/Observers/ValueConcurrentObserver.swift`, the
    /// `nonConstantRegionRecordedFromSelection` branch). Every awake surface holds its
    /// own observation, so each of their fetches ran there in turn and the next write —
    /// an arriving message, an outbox row moving, a read mark — queued behind all of
    /// them. The store is a `DatabasePool` (``BuzzEventStore``) precisely so that reads
    /// do not do that to writes.
    ///
    /// Declaring it constant also buys GRDB's own coalescing, which only this path
    /// reaches: `setNeedsFetching`'s `idle → fetching → fetchingAndNeedsFetch` states
    /// collapse a burst of commits into one fetch per observer, rather than serving
    /// every commit its own.
    ///
    /// # Why a `COUNT` per table is the whole job
    ///
    /// **Nobody reads the emitted value.** Every consumer is `for try await _ in`, and
    /// this observation carries no `removeDuplicates()`, so GRDB re-fires on the
    /// *region* and not on the value. All the fetch owes us is to name the region.
    ///
    /// And a count names *more* of the region than a column list does, not less: the
    /// authorizer reports `COUNT(*)` with an **empty** column name, which GRDB unions as
    /// the whole table, where a named column unions only that column
    /// (`GRDB/Core/StatementAuthorizer.swift`, its `SQLITE_READ` case). So the in-place
    /// updates this used to spell out column by column — an outbox row going `pending →
    /// sending`, a picture going `staged → uploaded`, a `read_at` frontier advancing, a
    /// second `thread_fetch` of the same root — all still re-fire, and now so does a
    /// write to any *other* column of those tables. Wider, never narrower.
    ///
    /// What went with the columns was the hand-folded token: ~2,500 rows off a real
    /// device store, materialised into `Row`s and hashed, to build an `Int` that was
    /// thrown away at both ends.
    private static var tracked: ValueObservation<ValueReducers.Fetch<Int>> {
        ValueObservation
            .trackingConstantRegion { db in
                var token = 0
                for table in trackedTables {
                    token &+= try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
                }
                return token
            }
    }

    /// The tables ``tracked`` watches, named once so the region and the reasoning above
    /// it cannot drift apart.
    ///
    /// - `event` — append-only, so a message, edit, deletion, reaction, profile (kind 0)
    ///   or channel-metadata (kind 39000) event is a *new* row here, projected in the
    ///   same write (see `BuzzEventStore.write`).
    /// - `outbox` / `outbox_media` — an optimistic send and every delivery-state change,
    ///   down to the per-picture progress the pending row's "Sending… (2/5)" counts.
    /// - `read_state` — this device marking a channel read, or another device's blob
    ///   arriving; either moves an unread count.
    /// - `thread_fetch` — this device recording that it now holds a thread in full,
    ///   which changes that message's reply tally (see
    ///   `BuzzEventStore.recordThreadFetch`). It is the one such change that can happen
    ///   with **no event row behind it**: opening a thread whose replies were all
    ///   withdrawn ingests nothing, so the badge would go on advertising replies that
    ///   are not there until some unrelated event happened along.
    /// - `channel_access` — directory snapshots and accepted lifecycle commands update
    ///   it without necessarily inserting a relay event.
    private static let trackedTables = [
        "event",
        "outbox",
        "outbox_media",
        "read_state",
        "thread_fetch",
        "channel_access",
    ]

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
    ///
    /// Constant-region for the reason ``tracked`` is: one table, read unconditionally,
    /// and a non-constant region would fetch on the write connection.
    static func composerDrafts(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        ValueObservation
            .trackingConstantRegion { db in
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
    ///
    /// Constant-region for the reason ``tracked`` is; here the value *is* read, and a
    /// count is unaffected by where it is fetched.
    static func draftCount(in reader: any DatabaseReader) -> AsyncValueObservation<Int> {
        ValueObservation
            .trackingConstantRegion { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM composer_draft") ?? 0
            }
            .removeDuplicates()
            .values(in: reader)
    }
}
