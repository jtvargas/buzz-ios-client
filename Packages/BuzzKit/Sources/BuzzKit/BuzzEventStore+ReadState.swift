import Foundation
import GRDB
import NostrCore
import Security

/// The read-state seam onto the store: the replaceable per-slot upsert of a
/// decrypted NIP-RS blob, the own-slot read-back that builds the next blob, and the
/// durable installation identity (`client_id` / `slot-id`).
///
/// Read state is a *precious local* table, not a projection — see the
/// `v3.read-state` migration for why the pure projector cannot rebuild it. The
/// engine, which holds the identity, decrypts an incoming `kind:30078` and calls
/// ``applyReadState(author:slot:contexts:sourceCreatedAt:sourceEventID:)``; the store
/// never touches the secret.
public extension BuzzEventStore {
    /// One device's blob as stored: its contexts and the `(created_at, id)` of the
    /// event they came from, so the engine can build a strictly-newer replacement
    /// (NIP-RS clock-skew monotonicity) without a stale-timestamp collision.
    struct ReadStateSlot: Sendable, Equatable {
        public let contexts: [String: Int64]
        public let sourceCreatedAt: Int64
        public let sourceEventID: String
    }

    // MARK: - Apply (write)

    /// Applies one decrypted blob for `(author, slot)`, replacing that slot's stored
    /// contexts wholesale — the addressable-event "newest per coordinate" rule, not
    /// an append. Guarded by the full `(created_at, event_id)` cursor so an older
    /// blob a relay resends after a reconnect cannot clobber a newer one, and so the
    /// replace lands the same rows under live ingest and an ordered replay.
    ///
    /// The effective read frontier a channel reads is `MAX(read_at)` across *all*
    /// slots, so replacing one slot never lowers another device's frontier — the
    /// grow-only merge lives in the read, this write only keeps each slot current.
    func applyReadState(
        author: String,
        slot: String,
        contexts: [String: Int64],
        sourceCreatedAt: Int64,
        sourceEventID: String
    ) async throws {
        let source = WindowCursor(createdAt: sourceCreatedAt, id: sourceEventID)
        try await writer.write { db in
            try Self.applyReadState(author: author, slot: slot, contexts: contexts, source: source, into: db)
        }
    }

    // MARK: - Own slot (read)

    /// This installation's own stored blob for `slot`, or `nil` when it has none yet.
    /// The engine reads it to accumulate the next grow-only blob (all previously
    /// marked contexts plus the newly read one) and to stamp a strictly-newer
    /// `created_at`.
    func ownReadStateSlot(author: String, slot: String) async throws -> ReadStateSlot? {
        try await reader.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT context_id, read_at, source_created_at, source_event_id
                FROM read_state WHERE author = ? AND slot = ?
                """,
                arguments: [author, slot]
            )
            guard let first = rows.first else { return nil }
            var contexts: [String: Int64] = [:]
            for row in rows {
                let context: String = row["context_id"]
                contexts[context] = row["read_at"]
            }
            return ReadStateSlot(
                contexts: contexts,
                sourceCreatedAt: first["source_created_at"],
                sourceEventID: first["source_event_id"]
            )
        }
    }

    /// The effective read frontier for one context — `MAX(read_at)` across every
    /// device's slot — or `nil` when no blob has ever marked it. Exposed for tests
    /// and diagnostics; the channel list computes the same value inline in SQL.
    func effectiveReadFrontier(context: String) async throws -> Int64? {
        try await reader.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT MAX(read_at) FROM read_state WHERE context_id = ?",
                arguments: [context]
            )
        }
    }

    // MARK: - Installation identity

    /// This installation's stable NIP-RS `client_id` and `slot-id`, generated once
    /// and persisted in `meta` (a precious table, so they survive a projection
    /// rebuild). The `client_id` identifies the device inside the encrypted blob; the
    /// random `slot-id` is the addressable-event key and has no relationship to it.
    func readStateIdentity() async throws -> (clientID: String, slotID: String) {
        try await writer.write { db in
            let clientID = try Self.persistedID(Self.readStateClientIDKey, into: db)
            let slotID = try Self.persistedID(Self.readStateSlotIDKey, into: db)
            return (clientID, slotID)
        }
    }
}

// MARK: - Internals

extension BuzzEventStore {
    static let readStateClientIDKey = "read_state_client_id"
    static let readStateSlotIDKey = "read_state_slot_id"

    /// The replaceable per-slot apply, static so it can run inside a caller's write
    /// transaction (the engine applies incoming and own-optimistic blobs the same way).
    static func applyReadState(
        author: String,
        slot: String,
        contexts: [String: Int64],
        source: WindowCursor,
        into db: Database
    ) throws {
        // Reject a blob no newer than the one already applied for this slot, comparing
        // the whole `(created_at, event_id)` cursor — the same guard the roster
        // projection uses so a same-second resend resolves identically live and on replay.
        if let existing = try Row.fetchOne(
            db,
            sql: "SELECT source_created_at, source_event_id FROM read_state WHERE author = ? AND slot = ? LIMIT 1",
            arguments: [author, slot]
        ) {
            let appliedAt: Int64 = existing["source_created_at"]
            let appliedID: String = existing["source_event_id"]
            if source <= WindowCursor(createdAt: appliedAt, id: appliedID) { return }
        }

        try db.execute(
            sql: "DELETE FROM read_state WHERE author = ? AND slot = ?",
            arguments: [author, slot]
        )
        for (context, readAt) in contexts {
            try db.execute(
                sql: """
                INSERT INTO read_state (author, slot, context_id, read_at, source_created_at, source_event_id)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [author, slot, context, readAt, source.createdAt, source.id]
            )
        }
    }

    /// Reads a persisted random id from `meta`, generating and storing one on first
    /// use. 16 random bytes rendered as 32 lowercase hex chars, matching the upstream
    /// slot/client id shape.
    static func persistedID(_ key: String, into db: Database) throws -> String {
        if let existing = try String.fetchOne(
            db,
            sql: "SELECT value FROM meta WHERE key = ?",
            arguments: [key]
        ) {
            return existing
        }
        let id = randomHex(byteCount: 16)
        try db.execute(
            sql: "INSERT INTO meta (key, value) VALUES (?, ?)",
            arguments: [key, id]
        )
        return id
    }

    /// `byteCount` cryptographically-random bytes as lowercase hex.
    static func randomHex(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        // A failed CSPRNG draw is not fatal here — fall back to UUID entropy so an
        // installation still gets a stable, unique id rather than crashing.
        if SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes) != errSecSuccess {
            let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            return String(uuid.prefix(byteCount * 2)).lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
