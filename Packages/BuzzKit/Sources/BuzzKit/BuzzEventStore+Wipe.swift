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
    func wipe() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM event") // ON DELETE CASCADE clears event_tag
            try db.execute(sql: "DELETE FROM outbox")
            try db.execute(sql: "DELETE FROM channel_sync")
            try db.execute(sql: "DELETE FROM read_state")
            for table in Schema.projectionTables {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }
}
