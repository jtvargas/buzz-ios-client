@testable import BuzzKit
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

    func open(
        projector: any EventProjecting = NullProjector(),
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
}
