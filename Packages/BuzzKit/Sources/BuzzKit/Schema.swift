import Foundation
import GRDB

/// The BuzzKit database schema.
///
/// Two families of table live here and they have opposite lifecycles.
///
/// `event` and `event_tag` are the source of truth: an append-only mirror of the
/// wire, never updated in place, and migrated with real care because losing them
/// means refetching from a relay that may no longer hold the history. Every other
/// table is a *projection* — a disposable index derived from that log. Projections
/// are dropped and replayed whenever ``projectionVersion`` moves, so fixing a
/// parsing bug or adding a column costs a version bump rather than a migration and
/// a resync.
///
/// **Every table is a rowid table — never `WITHOUT ROWID`.** SQLite's update hook
/// does not fire for `WITHOUT ROWID` tables, and GRDB's `ValueObservation` is
/// built on that hook: the initial fetch succeeds and then no later change is ever
/// noticed. The entire UI layer is observation-driven, so the wasted rowid on a
/// content-addressed `TEXT` primary key is simply the price of the architecture
/// working at all.
enum Schema {
    /// Bump when any projection's shape or meaning changes. On the next open every
    /// projection table is dropped and replayed from `event`; the log is untouched.
    ///
    /// Step 1 shipped the tables and the rebuild mechanism at version 1. Step 2
    /// adds the real ``BuzzProjector`` — channel/roster/profile/thread/reaction/
    /// deletion/edit/rich-content/thread-summary rows, the owner-attestation index,
    /// and the staleness columns those need — so the version moves to 2. A later
    /// authority or parsing fix is another bump and a replay, never a resync.
    ///
    /// Version 3 corrects two projection defects that the rebuild path repairs for
    /// existing stores without a resync: the `deletion` table's primary key becomes
    /// composite `(event_id, target_id)` so a multi-target kind-5 tombstones every
    /// target rather than only its first, and `channel_member` gains a
    /// `source_event_id` column so a same-`created_at` roster tie resolves by event
    /// id identically in live ingest and an ordered replay.
    /// Version 4 adds the persisted Buzz agent directory (kind 10100), used by
    /// composer autocomplete to include eligible non-member agents.
    /// Version 5 adds the relay-authored archived bit to channel metadata.
    ///
    /// Version 6 lifts the thread summary's tallies out of its opaque payload into
    /// real columns, so the timeline can read a message's reply count without holding
    /// the replies. The rebuild refills them for an existing store at no network cost:
    /// a `kind:39005` is an ordinary logged event (``BuzzEventStore/commitWindowPage``
    /// admits `rows + aux + summaries` through the same choke point), so the replay
    /// re-derives every cached summary the store ever received.
    ///
    /// Version 7 keeps the relay's `["t", <type>]` on channel metadata, so a group
    /// direct message can be told from a private channel by what the relay says it is
    /// rather than by counting its roster. The rebuild reads it back out of every
    /// kind:39000 already in the log, so an existing store gains it without a resync.
    static let projectionVersion = 7

    /// The `meta` key under which the applied projection version is recorded.
    static let projectionVersionKey = "projection_version"

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1.log") { db in
            try createLogTables(db)
        }
        migrator.registerMigration("v1.local") { db in
            try createLocalTables(db)
        }
        migrator.registerMigration("v1.projections") { db in
            try createProjectionTables(db)
        }

        // The outbox gains a denormalized `kind` so the timeline and channel-list
        // unions can keep only queued *messages* (kind 9) and let queued reactions
        // (kind 7) or their withdrawals (kind 5) flow through the same durable send
        // path without masquerading as pending messages. Denormalized like
        // `channel_id`/`root_id`/`parent_id` before it, so the union never decodes
        // the payload JSON in SQL. Added by migration rather than folded into
        // `v1.local` so an existing store gains the column without a resync; the
        // `DEFAULT 9` backfills the messages that are all any prior row could be.
        migrator.registerMigration("v2.outbox-kind") { db in
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN kind INTEGER NOT NULL DEFAULT 9")
        }

        // NIP-RS cross-device read state. A *local* table, not a projection: its rows
        // are the decrypted plaintext of `kind:30078` blobs, and decryption needs the
        // identity's secret — which the pure ``BuzzProjector`` (a function of the event
        // alone, keyless, shared by live ingest and the version-bump replay) does not
        // have. A projection rebuild would only ever reproduce it empty, so it lives
        // with the other precious tables (``outbox``/``channel_sync``/``meta``) that a
        // rebuild must not erase. The engine decrypts an incoming blob and applies it
        // here; the relay re-delivers the latest replaceable blob per slot on every
        // reconnect, so this table is also self-healing from a fresh install.
        //
        // Keyed by `(author, slot)` — the addressable coordinate of one device's blob —
        // collapsed replaceable per slot (newest `(created_at, event_id)` wins). The
        // effective read frontier of a context is `MAX(read_at)` across every slot.
        migrator.registerMigration("v3.read-state") { db in
            try db.execute(sql: """
            CREATE TABLE read_state (
                author            TEXT NOT NULL,
                slot              TEXT NOT NULL,
                context_id        TEXT NOT NULL,
                read_at           INTEGER NOT NULL,
                source_created_at INTEGER NOT NULL,
                source_event_id   TEXT NOT NULL,
                PRIMARY KEY (author, slot, context_id)
            )
            """)
            // The channel-list unread join reads MAX(read_at) grouped by context id,
            // so index the context lookup.
            try db.execute(sql: "CREATE INDEX read_state_context ON read_state(context_id)")
        }

        // An author index. `event_timeline` scopes by group and says nothing about "what
        // did *this person* write" — the question ``fetchRecentMentions`` asks on every
        // commit: 63 ms without it over a 50k-event store, 2 ms with. A pure index
        // addition, so a migration rather than a ``projectionVersion`` bump.
        migrator.registerMigration("v4.event-author") { db in
            try db.execute(sql: "CREATE INDEX event_author ON event(pubkey, kind, created_at DESC)")
        }

        // Relay directory membership is authoritative for whether a cached channel
        // belongs in an identity's sidebar. This is precious local state: a failed
        // or partial directory refresh must leave the last complete snapshot intact,
        // and a projection rebuild must not erase it.
        migrator.registerMigration("v5.channel-lifecycle") { db in
            try db.execute(sql: """
            CREATE TABLE channel_access (
                identity_pubkey TEXT NOT NULL,
                channel_id      TEXT NOT NULL,
                state           TEXT NOT NULL,
                updated_at      INTEGER NOT NULL,
                PRIMARY KEY (identity_pubkey, channel_id)
            )
            """)
            try db.execute(
                sql: "CREATE INDEX channel_access_visible ON channel_access(identity_pubkey, state, channel_id)"
            )
            try db.execute(sql: """
            CREATE TABLE channel_directory_request (
                identity_pubkey TEXT PRIMARY KEY NOT NULL,
                generation      INTEGER NOT NULL
            )
            """)

            // Terminal relay refusals retain their content and reason, but must not
            // advertise an action that can only repeat the same refusal.
            try db.execute(sql: "ALTER TABLE outbox ADD COLUMN is_retryable INTEGER NOT NULL DEFAULT 1")
        }

        // A record that this device has held a thread in full, and of which relay
        // summary that fetch superseded.
        //
        // Local, not a projection, and the distinction is the whole point: it records
        // something about *this device's knowledge*, not about any event, so the pure
        // keyless ``BuzzProjector`` could not reproduce it and a rebuild replay would
        // only ever write it empty.
        //
        // It exists to settle which of two disagreeing tallies is the newer one. The
        // obvious way to ask that — compare timestamps — cannot be done honestly here:
        // a summary's `updated_at` is the *relay's* clock and a fetch happens on the
        // *device's*, so a phone whose clock runs slow would rule its own complete
        // count stale forever. So the fetch names the summary instead. `summary_event_id`
        // is whichever `kind:39005` was current for this root at the moment of the
        // fetch, or NULL when there was none, and the read's question becomes an
        // identity test with no clock in it: *is the summary on file still the one this
        // fetch already accounted for?* If it is, the local count is the later word. If
        // a different one has arrived since, the relay's is.
        //
        // Why the local word deserves to win at all: replies and their deletions are
        // ordinary stored events, so a live subscription's reconnect replay refills
        // whatever was missed while the app was away. The relay's tally has no such
        // recovery — it is pushed once, fan-out only, never stored (see
        // ``SyncEngine/contentFilter(for:)``) — so a push dropped by a full socket
        // buffer is gone, and a count composed as "whichever is larger" would keep
        // advertising a reply that was withdrawn during that gap, permanently and with
        // no way for the reader to correct it.
        migrator.registerMigration("v6.thread-fetch") { db in
            try db.execute(sql: """
            CREATE TABLE thread_fetch (
                root_id          TEXT PRIMARY KEY NOT NULL,
                summary_event_id TEXT
            )
            """)
        }

        // A record that this device has *attempted* a prefetch for a thread, and against
        // which relay summary. Local for the same reason ``thread_fetch`` is: it is a fact
        // about this device's knowledge, not about any event.
        //
        // It is the brake on the prefetch, and the prefetch needs one because its question
        // — "does the relay know about a reply newer than anything I hold?" — can become
        // permanently unanswerable. A reply that carries no NIP-10 `reply` marker resolves
        // to no parent and no root, so ``BuzzProjector`` writes it no `thread` row at all
        // (deliberately: only a real reply may be excluded from a channel timeline). The
        // relay counts that reply regardless — it does not share our threading
        // conventions — so `last_reply_at` sits permanently above anything local, the
        // predicate stays true no matter how often it is asked, and the same fetch is
        // reissued on every reconnect for the life of the process. `.ready` re-walks every
        // known channel, so one such reply anywhere is a background fetch that never stops.
        //
        // Recording the attempt turns that into one fetch per *new* summary: a thread costs
        // work when it gains activity, which is the same bound a well-formed thread has.
        //
        // Separate from ``thread_fetch`` rather than folded into it, because the two make
        // different claims. `thread_fetch` says "this device holds the thread in full", and
        // only an unclipped answer may say it — that claim is what suppresses the relay's
        // tally. This one says only "we already asked about this summary", which a clipped
        // answer may say perfectly well. Writing a bounded prefetch into `thread_fetch`
        // would suppress a larger and more correct relay count with a local one that is
        // genuinely short.
        migrator.registerMigration("v7.thread-prefetch") { db in
            try db.execute(sql: """
            CREATE TABLE thread_prefetch (
                root_id          TEXT PRIMARY KEY NOT NULL,
                summary_event_id TEXT
            )
            """)
            // The order the prefetch picks its candidates in. Also created by
            // ``createContentTables(_:)`` so a projection rebuild restores it — this branch
            // is for a store that already exists at v6, where that function has long since
            // run. Both spell it from the same string, which is `IF NOT EXISTS`.
            try db.execute(sql: threadSummaryRecentIndexSQL)
        }

        // The unsent text sitting in each conversation's composer.
        //
        // Local for the usual reason — it is a fact about this device, not about any
        // event, so the keyless projector could only ever rebuild it empty — and
        // *precious* for a sharper one: this is the only table holding words their
        // author has not decided to publish. That is what puts it here rather than in
        // `UserDefaults` beside the stars and the thread read marks, which hold ids.
        // ``BuzzEventStore/wipe()`` erases it on an identity change and vacuums the
        // file afterwards, so identity A's half-written message cannot survive on disk
        // into identity B's session; a defaults blob is covered by neither.
        //
        // Keyed by `(channel_id, root_id)` with `''` standing for "the channel's own
        // composer", which is the whole product requirement expressed as a primary key:
        // a channel and each of its threads are separate composers and cannot read each
        // other's text. `root_id` is `TEXT NOT NULL DEFAULT ''` rather than nullable
        // because SQLite does not treat two `NULL`s as equal in a primary key, so a
        // nullable column would let a channel accumulate a new draft row per save.
        //
        // `tokens` is an opaque payload the app layer owns and this layer never reads —
        // the mention tokens that carry a `@Name`'s pubkey, which the visible text does
        // not. Storing only `text` would restore a draft whose mentions look right and
        // notify nobody.
        //
        // Text only, deliberately. An attachment draft would be a second column here
        // (or a child table keyed the same way) plus a payload in
        // ``ComposerDraftRecord``; nothing else about this table would move.
        migrator.registerMigration("v8.composer-draft") { db in
            try db.execute(sql: """
            CREATE TABLE composer_draft (
                channel_id TEXT NOT NULL,
                root_id    TEXT NOT NULL DEFAULT '',
                text       TEXT NOT NULL,
                tokens     TEXT NOT NULL DEFAULT '',
                updated_at INTEGER NOT NULL,
                PRIMARY KEY (channel_id, root_id)
            )
            """)
            // The order the capacity trim keeps by. The composer's own read goes through
            // the primary key's implicit index and never touches this one; this is for
            // the trim, which runs on every save and reads it as a covering index.
            try db.execute(sql: "CREATE INDEX composer_draft_recency ON composer_draft(updated_at DESC)")
        }

        return migrator
    }

    // MARK: - Log (source of truth)

    /// The append-only event log and its single-letter tag index.
    private static func createLogTables(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE event (
            id          TEXT PRIMARY KEY NOT NULL,
            pubkey      TEXT NOT NULL,
            created_at  INTEGER NOT NULL,
            kind        INTEGER NOT NULL,
            content     TEXT NOT NULL,
            tags        TEXT NOT NULL,
            sig         TEXT NOT NULL,
            h           TEXT,
            received_at INTEGER NOT NULL
        )
        """)

        // Serves the channel timeline directly: scope by group, then kind, newest
        // first, with the id as a stable tiebreak for same-second events.
        try db.execute(sql: """
        CREATE INDEX event_timeline ON event(h, kind, created_at DESC, id)
        """)

        // Single-letter tags only. NIP-01 indexes only single letters, and
        // multi-character tags are read from the event's own `tags` JSON when
        // needed; indexing every tag would double the write cost for lookups
        // nobody performs.
        try db.execute(sql: """
        CREATE TABLE event_tag (
            event_id TEXT NOT NULL REFERENCES event(id) ON DELETE CASCADE,
            name     TEXT NOT NULL,
            value    TEXT NOT NULL,
            position INTEGER NOT NULL,
            PRIMARY KEY (event_id, name, position)
        )
        """)
        try db.execute(sql: "CREATE INDEX event_tag_lookup ON event_tag(name, value)")
    }

    // MARK: - Local state (precious, not derived)

    /// Tables that hold local decisions and durable sync bookkeeping. Unlike the
    /// projections these are never dropped by a version bump — a rebuild must not
    /// erase what could not be reconstructed from the log.
    private static func createLocalTables(_ db: Database) throws {
        // Messages signed but not yet acknowledged by the relay. The id exists the
        // moment we sign, so an outbox row and its eventual log row share an
        // identity and the UI animates pending -> sent instead of swapping rows.
        //
        // `pubkey`, `content`, `root_id`, `parent_id`, and `tags` are denormalized
        // out of `payload` so the timeline can union pending rows without decoding
        // a whole event's JSON in SQL.
        try db.execute(sql: """
        CREATE TABLE outbox (
            event_id   TEXT PRIMARY KEY NOT NULL,
            channel_id TEXT NOT NULL,
            pubkey     TEXT NOT NULL,
            content    TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            payload    TEXT NOT NULL,
            state      TEXT NOT NULL,
            attempts   INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            root_id    TEXT,
            parent_id  TEXT,
            tags       TEXT NOT NULL DEFAULT '[]'
        )
        """)
        try db.execute(sql: "CREATE INDEX outbox_channel ON outbox(channel_id, created_at)")

        // The durable per-channel watermark: the composite (created_at, id) cursor
        // below which local history is contiguous. `head_synced` records whether
        // the head window has been reconciled since the last fresh socket. This is
        // BuzzKit's reliability delta over a timestamp-only cursor — it closes
        // offline gaps exactly rather than refetching a fixed window.
        try db.execute(sql: """
        CREATE TABLE channel_sync (
            channel_id            TEXT PRIMARY KEY NOT NULL,
            watermark_created_at  INTEGER,
            watermark_id          TEXT,
            head_synced           INTEGER NOT NULL DEFAULT 0
        )
        """)

        try db.execute(sql: """
        CREATE TABLE meta (
            key   TEXT PRIMARY KEY NOT NULL,
            value TEXT NOT NULL
        )
        """)
    }

    // MARK: - Projections (disposable, rebuilt on version bump)

    /// Creates every projection table. Kept separate from the migration so the
    /// rebuild path recreates them through exactly this code, which is what stops
    /// a rebuilt schema from drifting from the migrated one.
    static func createProjectionTables(_ db: Database) throws {
        try createChannelTables(db)
        try createThreadingTables(db)
        try createContentTables(db)
    }

    /// Channel-identity projections: metadata, the member roster, and author
    /// profiles.
    private static func createChannelTables(_ db: Database) throws {
        // Channel metadata, kind 39000, relay-signed and addressable by `d`.
        try db.execute(sql: """
        CREATE TABLE channel (
            id              TEXT PRIMARY KEY NOT NULL,
            name            TEXT,
            about           TEXT,
            picture         TEXT,
            is_private      INTEGER NOT NULL DEFAULT 0,
            is_archived     INTEGER NOT NULL DEFAULT 0,
            -- The relay's own `["t", <type>]`: `stream`, `forum`, or `dm`. Held as the
            -- raw string rather than collapsed to a flag, because the relay has three
            -- types and a projection that only remembers the answer to today's question
            -- has to be re-derived from the log to answer tomorrow's. NULL for a channel
            -- whose metadata predates the tag, which is a *don't know* and not a `stream`.
            channel_type    TEXT,
            source_event_id TEXT NOT NULL,
            updated_at      INTEGER NOT NULL
        )
        """)

        // The relay-signed member roster, kind 39002. Authoritative and complete,
        // so the projector replaces rather than merges it. A roster is addressable
        // state a relay can resend older after a reconnect, and this projection
        // collapses to one roster per channel, so every row carries the source
        // event's `created_at` *and* its id: the projector reads both back to reject
        // a stale resend and to break a same-second tie by event id, so the replace
        // lands the same roster under live ingest and under an ordered rebuild.
        try db.execute(sql: """
        CREATE TABLE channel_member (
            channel_id        TEXT NOT NULL,
            pubkey            TEXT NOT NULL,
            role              TEXT,
            source_created_at INTEGER NOT NULL,
            source_event_id   TEXT NOT NULL,
            PRIMARY KEY (channel_id, pubkey)
        )
        """)

        // Relay-authored owner/admin roster (kind 39001). Kept separate from the
        // membership roster because a relay may omit roles from kind 39002.
        try db.execute(sql: """
        CREATE TABLE channel_admin (
            channel_id        TEXT NOT NULL,
            pubkey            TEXT NOT NULL,
            role              TEXT,
            source_created_at INTEGER NOT NULL,
            source_event_id   TEXT NOT NULL,
            PRIMARY KEY (channel_id, pubkey)
        )
        """)

        // Profile metadata, kind 0, replaceable per pubkey.
        try db.execute(sql: """
        CREATE TABLE profile (
            pubkey          TEXT PRIMARY KEY NOT NULL,
            display_name    TEXT,
            picture         TEXT,
            about           TEXT,
            nip05           TEXT,
            lud16           TEXT,
            source_event_id TEXT NOT NULL,
            created_at      INTEGER NOT NULL
        )
        """)

        try db.execute(sql: """
        CREATE TABLE agent_directory (
            pubkey               TEXT PRIMARY KEY NOT NULL,
            display_name         TEXT,
            respond_to           TEXT,
            respond_to_allowlist TEXT NOT NULL,
            channel_ids          TEXT NOT NULL,
            source_event_id      TEXT NOT NULL,
            created_at           INTEGER NOT NULL
        )
        """)
    }

    /// Engagement projections that hang off a target message: threading, reactions,
    /// deletions, and the verified owner attestations that widen delete/edit
    /// authority at read time.
    private static func createThreadingTables(_ db: Database) throws {
        // Threading derived from NIP-10 markers: one row per real reply, so the
        // channel timeline can exclude replies with a single NOT EXISTS rather than
        // decoding tag JSON for every message. `broadcast` replies were echoed to
        // the channel by their author and belong in both places.
        try db.execute(sql: """
        CREATE TABLE thread (
            event_id   TEXT PRIMARY KEY NOT NULL,
            root_id    TEXT NOT NULL,
            parent_id  TEXT NOT NULL,
            channel_id TEXT,
            pubkey     TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            broadcast  INTEGER NOT NULL DEFAULT 0
        )
        """)
        try db.execute(sql: "CREATE INDEX thread_root ON thread(root_id, created_at, event_id)")

        // Reactions, kind 7, keyed to their target event.
        try db.execute(sql: """
        CREATE TABLE reaction (
            event_id   TEXT PRIMARY KEY NOT NULL,
            target_id  TEXT NOT NULL,
            pubkey     TEXT NOT NULL,
            emoji      TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX reaction_target ON reaction(target_id)")

        // Deletions are recorded without judging them: whether one takes effect is
        // a read-time decision that needs the target's author (and, for an
        // agent-authored target, its verified NIP-OA owner). `kind` distinguishes a
        // NIP-29 relay tombstone (9005) from an author deletion (5).
        //
        // The key is composite `(event_id, target_id)`: one kind-5 can name several
        // `e` targets, and each must get its own row. Keyed on `event_id` alone, the
        // projector's `ON CONFLICT DO NOTHING` kept only the first target and dropped
        // the rest, so a multi-target deletion tombstoned just one message.
        try db.execute(sql: """
        CREATE TABLE deletion (
            event_id   TEXT NOT NULL,
            target_id  TEXT NOT NULL,
            deleted_by TEXT NOT NULL,
            kind       INTEGER NOT NULL DEFAULT 5,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (event_id, target_id)
        )
        """)
        try db.execute(sql: "CREATE INDEX deletion_target ON deletion(target_id)")

        // The verified NIP-OA owner of an event's author, recorded for any event
        // whose owner-signed `auth` tag checks out. It is a fact about the event,
        // not a judgment about any deletion or edit: the read-time authority
        // predicate joins it to widen delete/edit rights to a target author's
        // owner. Absent for ordinary human-authored events, which carry no
        // attestation. Rebuilding re-verifies from the log, so an attestation-logic
        // fix is a version bump, not a resync.
        try db.execute(sql: """
        CREATE TABLE event_owner (
            event_id     TEXT PRIMARY KEY NOT NULL,
            owner_pubkey TEXT NOT NULL
        )
        """)
    }

    /// Content-overlay projections: edits, rich content, and cached thread
    /// summaries.
    private static func createContentTables(_ db: Database) throws {
        // Buzz edits, kind 40003. The newest authorized edit wins at read time, so
        // the index carries created_at descending.
        try db.execute(sql: """
        CREATE TABLE edit (
            event_id   TEXT PRIMARY KEY NOT NULL,
            target_id  TEXT NOT NULL,
            pubkey     TEXT NOT NULL,
            content    TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """)
        try db.execute(sql: "CREATE INDEX edit_target ON edit(target_id, created_at DESC)")

        // Buzz rich content, kind 40002, replaced per target. The renderer falls
        // back to the target's plain `content` when this is absent. Kind 40002 is a
        // regular event, so several may target one message over time; `created_at`
        // guards the replace so the newest payload wins whatever order they arrive
        // or replay in, rather than the last one written.
        try db.execute(sql: """
        CREATE TABLE rich_content (
            target_id  TEXT PRIMARY KEY NOT NULL,
            event_id   TEXT NOT NULL,
            payload    TEXT NOT NULL,
            created_at INTEGER NOT NULL
        )
        """)

        // Cached relay-signed thread-summary overlays, kind 39005, keyed by the
        // root id they describe (their `d` binding). Latest-wins per root, guarded
        // by `updated_at`, since a relay can resend an older overlay on reconnect.
        //
        // The two tallies the timeline reads are lifted out of `payload` into real
        // columns, because it reads them for every message on every screen and
        // `json_extract` over a text blob is a parse per row per read that no index can
        // help. Only those two: the blob stays beside them and remains the record of
        // what the relay actually said, so a field this version does not read — the
        // direct-child `reply_count`, `participants` — is not lost, merely not lifted.
        //
        // Nullable, both, and deliberately: a payload this client cannot parse must
        // leave a summary that says nothing rather than one that says zero. Zero is an
        // assertion — "this thread has no replies" — and it would take a message's
        // existing CTA *away* on the strength of a field we failed to read.
        try db.execute(sql: """
        CREATE TABLE thread_summary (
            root_id          TEXT PRIMARY KEY NOT NULL,
            event_id         TEXT NOT NULL,
            payload          TEXT NOT NULL,
            updated_at       INTEGER NOT NULL,
            descendant_count INTEGER,
            last_reply_at    INTEGER
        )
        """)

        // Most recently active thread first, which is the order the prefetch chooses its
        // twenty in (``BuzzEventStore/threadPrefetchCandidates(channel:limit:)``). Without
        // it that read scans every summary and sorts them to answer a question about the
        // top of the list — and it evaluates a per-row correlated subquery while doing it,
        // so the cost is the whole table rather than the twenty rows wanted. `IF NOT
        // EXISTS` because the migration that introduced this index for existing installs
        // creates the same one; a fresh install runs both, and a projection rebuild drops
        // and re-runs this.
        try db.execute(sql: Self.threadSummaryRecentIndexSQL)
    }

    /// Shared between ``createContentTables(_:)`` and the migration that adds the index to
    /// a store created before it existed, so the two cannot define it differently.
    static let threadSummaryRecentIndexSQL = """
    CREATE INDEX IF NOT EXISTS thread_summary_recent ON thread_summary(last_reply_at DESC)
    """

    /// Every projection table, in an order safe to drop (no cross-table foreign
    /// keys bind them).
    static let projectionTables = [
        "thread_summary", "rich_content", "edit", "deletion", "event_owner",
        "reaction", "thread", "agent_directory", "profile",
        "channel_admin", "channel_member", "channel",
    ]

    static func dropProjectionTables(_ db: Database) throws {
        for table in projectionTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
}
