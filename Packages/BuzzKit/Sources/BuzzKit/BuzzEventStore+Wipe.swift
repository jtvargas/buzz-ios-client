import Foundation
import GRDB

public extension BuzzEventStore {
    /// Erases every stored row for an identity change, so a different key logging in
    /// on this device can never see the previous identity's history.
    ///
    /// The app defers the wipe decision to login: it keeps the store for a same-key
    /// re-login (fast, history intact) and calls this only when a *different* key
    /// takes over. Everything derivable from the relay is dropped — the append-only
    /// `event` log (which cascades `event_tag`), every projection, and the precious
    /// local tables (`outbox`, `channel_sync`, `read_state`). `meta` is preserved so
    /// the projection version still matches and no rebuild is triggered; the empty
    /// projections are already consistent with the now-empty log.
    ///
    /// The store self-heals from the relay on the next ``SyncEngine/start()``.
    ///
    /// Deleting rows alone is not forensic-clean: the old identity's plaintext would
    /// linger in SQLite's free pages and the WAL until reused. So the delete is
    /// followed by a `VACUUM`, which rewrites the database file — dropping every free
    /// page and checkpointing/truncating the WAL — so no residue of identity A
    /// survives on disk for identity B. `VACUUM` cannot run inside a transaction, so
    /// it follows the delete write (GRDB's `vacuum()` runs it outside one). Rewriting
    /// the whole file is inexpensive at a client store's scale and runs only on an
    /// identity change.
    func wipe() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM event") // ON DELETE CASCADE clears event_tag
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "DELETE FROM channel_sync")
            try db.execute(sql: "DELETE FROM channel_access")
            try db.execute(sql: "DELETE FROM channel_directory_request")
            try db.execute(sql: "DELETE FROM read_state")
            for table in Schema.projectionTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
        try await writer.vacuum()
    }
}
