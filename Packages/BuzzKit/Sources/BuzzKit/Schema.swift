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
    static let projectionVersion = 3

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
        try db.execute(sql: """
        CREATE TABLE thread_summary (
            root_id    TEXT PRIMARY KEY NOT NULL,
            event_id   TEXT NOT NULL,
            payload    TEXT NOT NULL,
            updated_at INTEGER NOT NULL
        )
        """)
    }

    /// Every projection table, in an order safe to drop (no cross-table foreign
    /// keys bind them).
    static let projectionTables = [
        "thread_summary", "rich_content", "edit", "deletion", "event_owner",
        "reaction", "thread", "profile", "channel_member", "channel",
    ]

    static func dropProjectionTables(_ db: Database) throws {
        for table in projectionTables {
            try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
        }
    }
}
