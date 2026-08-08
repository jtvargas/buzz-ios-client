import GRDB

extension Schema {
    /// Creates the durable full-text index over immutable message and edit events.
    ///
    /// The external-content source deliberately depends only on `event`, never on
    /// `edit`, `deletion`, `event_owner`, or another disposable projection. Search
    /// decides which source event is the current authorized text when it reads the
    /// index. That keeps a projection-version rebuild from recreating or repopulating
    /// the FTS table, while an explicit FTS `rebuild` always derives the same tokens
    /// from the append-only log.
    ///
    /// Deleted and unauthorized text retains tokens here. This exposes no plaintext
    /// the store does not already retain forever in `event`, and the search query's
    /// authority predicates prevent those tokens from producing a result. Filtering
    /// them out of this view would make the durable index depend on disposable state
    /// and break that rebuild guarantee.
    static func createMessageSearch(_ db: Database) throws {
        try db.execute(sql: """
        CREATE VIEW message_search_source AS
        SELECT rowid, content
          FROM event
         WHERE kind IN (9, 40003);

        CREATE VIRTUAL TABLE message_search USING fts5(
            content,
            content = 'message_search_source',
            content_rowid = 'rowid',
            tokenize = 'unicode61 remove_diacritics 2'
        );

        CREATE TRIGGER message_search_event_insert
        AFTER INSERT ON event
        WHEN new.kind IN (9, 40003)
        BEGIN
            INSERT INTO message_search(rowid, content) VALUES (new.rowid, new.content);
        END;

        CREATE TRIGGER message_search_event_delete
        AFTER DELETE ON event
        WHEN old.kind IN (9, 40003)
        BEGIN
            INSERT INTO message_search(message_search, rowid, content)
            VALUES ('delete', old.rowid, old.content);
        END;

        INSERT INTO message_search(rowid, content)
        SELECT rowid, content FROM message_search_source;
        """)
    }
}
