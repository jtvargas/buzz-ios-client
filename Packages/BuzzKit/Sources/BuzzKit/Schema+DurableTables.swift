import GRDB

extension Schema {
    static func createOutboxMediaTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE outbox_media (
            event_id   TEXT NOT NULL,
            sha256     TEXT NOT NULL,
            ordinal    INTEGER NOT NULL,
            ext        TEXT NOT NULL,
            mime       TEXT NOT NULL,
            size       INTEGER NOT NULL,
            state      TEXT NOT NULL,
            attempts   INTEGER NOT NULL DEFAULT 0,
            last_error TEXT,
            PRIMARY KEY (event_id, sha256)
        );
        CREATE INDEX outbox_media_event ON outbox_media(event_id);
        """)
    }

    // MARK: - Log (source of truth)

    /// The append-only event log and its single-letter tag index.
    static func createLogTables(_ db: Database) throws {
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
    static func createLocalTables(_ db: Database) throws {
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
}
