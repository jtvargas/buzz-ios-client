@testable import BuzzKit
import CryptoKit
import Foundation
import GRDB
import NostrCore

/// Builds signed events for tests. One key per instance, so authorship is stable
/// across a fixture's events.
///
/// A thin shim over `NostrEvent.signed` — the same production signing path
/// NostrCore's own fixtures run through — so every event a test admits is signed
/// exactly as one off the wire would be.
struct Fixture {
    let key: PrivateKey

    init() throws {
        key = try PrivateKey()
    }

    var pubkey: String {
        key.publicKey.hex
    }

    func event(
        _ kind: EventKind,
        _ content: String = "",
        tags: [[String]] = [],
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(seconds)),
            with: key
        )
    }

    /// A kind-9 channel message scoped to a group by its `h` tag.
    func message(
        _ content: String,
        in channel: String = "room-1",
        at seconds: Int64 = 1_700_000_000
    ) throws -> NostrEvent {
        try event(.channelMessage, content, tags: [["h", channel]], at: seconds)
    }

    /// An owner-signed NIP-OA `auth` tag by which this fixture, acting as the
    /// owner, authorizes `agentPubkey`.
    ///
    /// The owner signs `SHA-256` of `nostr:agent-auth:<agentPubkey>:<conditions>`,
    /// following the NIP-OA preimage construction, so a message an agent publishes
    /// carrying this tag exposes this fixture as its verified owner.
    func authTag(authorizing agentPubkey: String, conditions: String = "") throws -> [String] {
        let preimage = Data(("nostr:agent-auth:" + agentPubkey + ":" + conditions).utf8)
        let digest = Data(SHA256.hash(data: preimage))
        let signature = try key.signature(for: digest)
        return ["auth", pubkey, conditions, signature.hexString]
    }
}

/// A unique on-disk database for one test, opened as the real WAL `DatabasePool`
/// the store uses in production — so the observation and rebuild tests exercise
/// the shipping configuration, not a queue stand-in.
///
/// Call ``remove()`` from a `defer`; it clears the main file and its WAL/SHM
/// siblings.
struct TempDatabase {
    let path: String

    init() {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("buzzkit-\(UUID().uuidString).sqlite")
            .path
    }

    /// Opens the store with the production ``BuzzProjector`` by default, so the
    /// projection and timeline tests exercise exactly the shipping projector.
    /// Tests that only care about the log or the rebuild seam pass a
    /// ``NullProjector`` or a recording double instead.
    func open(
        projector: any EventProjecting = BuzzProjector(),
        projectionVersion: Int = Schema.projectionVersion
    ) throws -> BuzzEventStore {
        try BuzzEventStore(path: path, projector: projector, projectionVersion: projectionVersion)
    }

    func remove() {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: path + suffix)
        }
    }
}

/// A projector that records the events it is asked to project instead of writing
/// rows.
///
/// Lets a test assert that the rebuild path drives the seam over the whole log, in
/// log order, without depending on a real projector's row shapes. Thread-safe
/// because `project` runs on GRDB's writer queue, off the actor.
final class RecordingProjector: EventProjecting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [NostrEvent] = []

    var events: [NostrEvent] {
        lock.withLock { recorded }
    }

    func reset() {
        lock.withLock { recorded = [] }
    }

    func project(_ event: NostrEvent, into _: Database) throws {
        lock.withLock { recorded.append(event) }
    }
}

// MARK: - Read helpers

extension BuzzEventStore {
    /// Row count of a table, for asserting projection sizes.
    nonisolated func rowCount(_ table: String) async throws -> Int {
        try await reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }

    /// A single `meta` value, or `nil` when the key is absent.
    nonisolated func metaValue(_ key: String) async throws -> String? {
        try await reader.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    /// One text column of a query, in query order.
    nonisolated func strings(_ sql: String, column: String) async throws -> [String?] {
        try await reader.read { db in
            try Row.fetchAll(db, sql: sql).map { $0[column] as String? }
        }
    }

    /// Test-only raw write on the store's own connection, for seeding a row a
    /// rebuild must then erase.
    func executeForTest(_ sql: String) async throws {
        try await writer.write { db in
            try db.execute(sql: sql)
        }
    }

    /// Inserts a denormalized pending-send row directly, standing in for the Outbox
    /// component that lands in step 4, so the timeline's outbox UNION can be
    /// exercised now. The columns mirror what an enqueue will write.
    func enqueueForTest(
        _ event: NostrEvent,
        channel: String,
        state: String = "pending",
        lastError: String? = nil,
        rootID: String? = nil,
        parentID: String? = nil
    ) async throws {
        let payloadData = try JSONEncoder().encode(event)
        let tagsData = try JSONEncoder().encode(event.tags)
        // JSONEncoder always emits UTF-8, so the fallbacks are unreachable; the
        // failable initializer keeps this honest rather than force-decoding.
        let payload = String(bytes: payloadData, encoding: .utf8) ?? "{}"
        let tagsJSON = String(bytes: tagsData, encoding: .utf8) ?? "[]"
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO outbox
                    (event_id, channel_id, pubkey, content, created_at,
                     payload, state, attempts, last_error, root_id, parent_id, tags)
                VALUES (?, ?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?)
                """,
                arguments: [
                    event.id, channel, event.pubkey, event.content, event.createdAt,
                    payload, state, lastError, rootID, parentID, tagsJSON,
                ]
            )
        }
    }

    /// A deterministic dump of every projection table's contents.
    ///
    /// Row descriptions are sorted, so the comparison is over contents rather than
    /// insertion order — which differs between live ingest and an ordered replay.
    /// This is what a rebuild-agreement test asserts equal before and after a
    /// version bump.
    nonisolated func projectionSnapshot() async throws -> [String: [String]] {
        try await reader.read { db in
            var snapshot: [String: [String]] = [:]
            for table in Schema.projectionTables {
                let rows = try Row.fetchAll(db, sql: "SELECT * FROM \(table)")
                snapshot[table] = rows.map(\.description).sorted()
            }
            return snapshot
        }
    }
}
