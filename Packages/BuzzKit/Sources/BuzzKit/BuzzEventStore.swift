import Foundation
import GRDB
import NostrCore

/// The persistence layer, and the only place events enter BuzzKit's storage.
///
/// ``ingest(batch:phase:)`` is the single verification choke point. Nothing else
/// writes to the log, and nothing re-verifies on read, so the invariant *every
/// stored event was cryptographically valid at the moment it was stored* holds as
/// long as this one actor is correct. That is why the adversarial tests point
/// here.
///
/// The store owns the writer. Reads run against a `nonisolated` reader so
/// observation and queries can be set up off the actor, but the write connection
/// never leaves it — every mutation goes through ``ingest(batch:phase:)`` or the
/// rebuild path, both of which run one batch as one transaction.
///
/// Backed by a WAL `DatabasePool`: concurrent reads under a single serialized
/// writer, which is exactly the shape of an observation-driven UI reading while
/// the sync engine writes.
public actor BuzzEventStore {
    /// The write connection, owned by the actor. Internal so the outbox and the
    /// window client (later steps) can share the same connection, and with it the
    /// same transaction semantics.
    let writer: any DatabaseWriter

    /// A read-only handle, safe to use off the actor. Callers set up
    /// `ValueObservation` and run queries against it; it can never write.
    public nonisolated let reader: any DatabaseReader

    /// The projection seam. Step 1 wires ``NullProjector``; step 2 swaps in the
    /// real projector without this actor changing.
    let projector: any EventProjecting

    /// The projection version this store enforces. Defaults to the schema constant
    /// in production; injected in tests so the "the version moved" rebuild can be
    /// exercised without shipping a second build.
    let projectionVersion: Int

    /// The store's notion of "now", injected so the outbox's age-based decisions
    /// stay deterministic. The stale-timestamp re-sign (below) turns on the local
    /// age of a queued send, and the relay's ±15-minute ingest gate makes that age
    /// a correctness boundary, not a heuristic — so it must be a value a test can
    /// control rather than a wall-clock read buried in the logic. Defaults to the
    /// wall clock in production.
    let clock: @Sendable () -> Date

    // MARK: - Lifecycle

    /// Opens (or creates) the store at `path` with the production projector.
    public init(path: String) throws {
        let pool = try Self.makePool(path: path)
        writer = pool
        reader = pool
        projector = NullProjector()
        projectionVersion = Schema.projectionVersion
        clock = { Date() }
        try Self.prepare(pool, projector: projector, projectionVersion: projectionVersion)
    }

    /// Opens the store with an explicit projector and projection version.
    ///
    /// The seam tests and the rebuild tests drive the store through here. Kept
    /// internal so the public surface stays `init(path:)`.
    init(
        path: String,
        projector: any EventProjecting,
        projectionVersion: Int = Schema.projectionVersion,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        let pool = try Self.makePool(path: path)
        writer = pool
        reader = pool
        self.projector = projector
        self.projectionVersion = projectionVersion
        self.clock = clock
        try Self.prepare(pool, projector: projector, projectionVersion: projectionVersion)
    }

    private static func makePool(path: String) throws -> DatabasePool {
        var config = Configuration()
        // The `event_tag` -> `event` foreign key is only enforced with this on;
        // SQLite defaults it off per connection.
        config.foreignKeysEnabled = true
        // A `DatabasePool` runs in WAL mode by design, which is what lets readers
        // and the writer proceed concurrently.
        return try DatabasePool(path: path, configuration: config)
    }

    private static func prepare(
        _ writer: any DatabaseWriter,
        projector: any EventProjecting,
        projectionVersion: Int
    ) throws {
        try Schema.migrator.migrate(writer)
        try rebuildProjectionsIfStale(writer, projector: projector, projectionVersion: projectionVersion)
    }

    // MARK: - Ingest

    /// Verifies and stores a batch, reporting what happened to each event.
    ///
    /// The whole batch commits in one transaction. Partial application would leave
    /// the log and its projections describing different worlds — a message present
    /// with no thread row, a reaction with no target — which no later read could
    /// untangle.
    ///
    /// Verification runs *before* the write transaction and *in parallel*: a
    /// Schnorr check is the expensive part of admitting an event, and a backfill
    /// batch of hundreds would otherwise verify serially while holding, or about to
    /// hold, the write lock. Fanning the checks across a task group verifies across
    /// cores; only the already-admitted events reach the single write.
    ///
    /// - Ephemeral kinds (presence, typing) are verified — the caller is going to
    ///   act on them — then diverted into ``IngestResult/ephemeral`` and never
    ///   written; storing them would grow the log without bound for data that is
    ///   meaningless within seconds.
    /// - Duplicates are free and silent: the content-addressed id means a second
    ///   copy is by definition identical, so reconnect overlap and echoed sends
    ///   cost nothing.
    ///
    /// - Parameter phase: whether the batch is bounded backfill or the live
    ///   trickle. Carried for parity with the sink and reserved for the later
    ///   engine steps; step 1 stores both the same way.
    @discardableResult
    public func ingest(batch: [NostrEvent], phase _: IngestPhase) async throws -> IngestResult {
        guard !batch.isEmpty else { return IngestResult() }

        let verdicts = await Self.verify(batch)

        var result = IngestResult()
        var writable: [NostrEvent] = []
        writable.reserveCapacity(batch.count)

        for (event, verdict) in zip(batch, verdicts) {
            switch verdict {
            case .idMismatch:
                result.rejected.append(Rejection(id: event.id, reason: .idMismatch))
            case .badSignature:
                result.rejected.append(Rejection(id: event.id, reason: .badSignature))
            case .valid:
                if event.kind.isEphemeral {
                    result.ephemeral.append(event)
                } else {
                    writable.append(event)
                }
            }
        }

        guard !writable.isEmpty else { return result }

        let receivedAt = Int64(Date().timeIntervalSince1970)
        let projector = projector
        let toWrite = writable
        let outcome = try await writer.write { db -> WriteOutcome in
            var outcome = WriteOutcome()
            for event in toWrite {
                if try Self.write(event, receivedAt: receivedAt, projector: projector, into: db) {
                    outcome.inserted.append(event.id)
                } else {
                    outcome.duplicates.append(event.id)
                }
            }
            return outcome
        }

        result.inserted = outcome.inserted
        result.duplicates = outcome.duplicates
        return result
    }

    /// The outcome of verifying one event, before the batch is partitioned.
    private enum Verdict: Sendable {
        case valid
        case idMismatch
        case badSignature
    }

    /// The insert/duplicate split, returned Sendable from the write closure so the
    /// result is assembled on the actor rather than mutated across the boundary.
    private struct WriteOutcome: Sendable {
        var inserted: [String] = []
        var duplicates: [String] = []
    }

    /// Verifies a batch, preserving input order in the returned verdicts.
    ///
    /// A single event verifies inline — a task group per live message would cost
    /// more than the check it parallelizes. Larger batches fan out.
    private static func verify(_ batch: [NostrEvent]) async -> [Verdict] {
        if batch.count == 1 {
            return [verify(batch[0])]
        }
        return await withTaskGroup(of: (Int, Verdict).self) { group in
            for (index, event) in batch.enumerated() {
                group.addTask { (index, verify(event)) }
            }
            var verdicts = [Verdict](repeating: .valid, count: batch.count)
            for await (index, verdict) in group {
                verdicts[index] = verdict
            }
            return verdicts
        }
    }

    /// Recomputes the id and verifies the signature. Both are required: a valid id
    /// with a bad signature is a forgery, and a valid signature over a swapped id
    /// is the relay content-swap the id recomputation closes.
    private static func verify(_ event: NostrEvent) -> Verdict {
        guard event.hasValidID else { return .idMismatch }
        guard event.isValid else { return .badSignature }
        return .valid
    }

    /// Writes one already-verified event and projects it. Returns `false` when the
    /// event was already in the log.
    ///
    /// Below the choke point, not part of it: the caller must have verified the
    /// event. Shared with the rebuild path so an event lands by exactly the same
    /// route however it arrived.
    static func write(
        _ event: NostrEvent,
        receivedAt: Int64,
        projector: any EventProjecting,
        into db: Database
    ) throws -> Bool {
        try db.execute(
            sql: """
            INSERT INTO event (id, pubkey, created_at, kind, content, tags, sig, h, received_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [
                event.id,
                event.pubkey,
                event.createdAt,
                event.kind.rawValue,
                event.content,
                encodeTags(event.tags),
                event.sig,
                event.groupID,
                receivedAt,
            ]
        )

        // `ON CONFLICT DO NOTHING` makes zero changes the signal that this event
        // was already stored, so a duplicate never re-indexes or re-projects.
        guard db.changesCount > 0 else { return false }

        try insertTags(event, into: db)
        try projector.project(event, into: db)
        return true
    }

    /// Indexes single-letter tags for `#e` / `#p` style lookups. Multi-character
    /// tags are read from the event's `tags` JSON when needed.
    private static func insertTags(_ event: NostrEvent, into db: Database) throws {
        for (position, tag) in event.tags.enumerated() {
            guard let name = tag.first, name.count == 1, tag.count > 1 else { continue }
            try db.execute(
                sql: "INSERT INTO event_tag (event_id, name, value, position) VALUES (?, ?, ?, ?)",
                arguments: [event.id, name, tag[1], position]
            )
        }
    }

    private static func encodeTags(_ tags: [[String]]) throws -> String {
        let data = try JSONEncoder().encode(tags)
        guard let json = String(bytes: data, encoding: .utf8) else {
            // Unreachable: JSONEncoder always emits UTF-8. Kept as an honest
            // failure path rather than a force unwrap.
            throw StoreError.tagEncodingFailed
        }
        return json
    }

    /// Errors raised by the store's own encoding, distinct from GRDB and codec
    /// errors that surface as thrown `DatabaseError`/`DecodingError`.
    enum StoreError: Error {
        case tagEncodingFailed
    }

    // MARK: - Reads

    /// Reconstructs an event from the log. Used by tests and by later reconciliation
    /// paths; the UI reads projections and timeline rows instead.
    public func event(id: String) async throws -> NostrEvent? {
        try await reader.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM event WHERE id = ?", arguments: [id])
                .map(Self.decode)
        }
    }

    /// Counts stored events, optionally of one kind.
    public func count(kind: EventKind? = nil) async throws -> Int {
        try await reader.read { db in
            if let kind {
                try Int.fetchOne(
                    db,
                    sql: "SELECT COUNT(*) FROM event WHERE kind = ?",
                    arguments: [kind.rawValue]
                ) ?? 0
            } else {
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
            }
        }
    }

    static func decode(_ row: Row) -> NostrEvent {
        let tagsJSON: String = row["tags"]
        let tags = (try? JSONDecoder().decode([[String]].self, from: Data(tagsJSON.utf8))) ?? []
        return NostrEvent(
            id: row["id"],
            pubkey: row["pubkey"],
            createdAt: row["created_at"],
            kind: EventKind(rawValue: row["kind"]),
            tags: tags,
            content: row["content"],
            sig: row["sig"]
        )
    }

    // MARK: - Projection rebuild

    /// Drops and replays every projection when the stored version has moved on.
    ///
    /// This is the payoff of keeping the log authoritative: a projection bug or a
    /// new projection is a version bump and a replay, never a resync from a relay
    /// that may no longer hold the history. Runs at open, inside one transaction so
    /// a crash mid-rebuild leaves the previous projections in place.
    private static func rebuildProjectionsIfStale(
        _ writer: any DatabaseWriter,
        projector: any EventProjecting,
        projectionVersion: Int
    ) throws {
        try writer.write { db in
            let stored = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Schema.projectionVersionKey]
            )
            guard stored != String(projectionVersion) else { return }

            try Schema.dropProjectionTables(db)
            try Schema.createProjectionTables(db)
            try replayProjections(db, projector: projector)

            try db.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [Schema.projectionVersionKey, String(projectionVersion)]
            )
        }
    }

    /// Replays the whole log in the order it happened.
    ///
    /// Order matters: projections settle on "newer wins", so replaying out of order
    /// would land on different rows than live ingest did. The `id` tiebreak keeps
    /// same-second events in a stable order across replays.
    private static func replayProjections(_ db: Database, projector: any EventProjecting) throws {
        let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM event ORDER BY created_at ASC, id ASC")
        while let row = try cursor.next() {
            try projector.project(decode(row), into: db)
        }
    }

    /// Forces a projection rebuild. Exposed so tests — and, later, a manual repair
    /// path — can assert live and replayed projections agree.
    public func rebuildProjections() async throws {
        let projector = projector
        try await writer.write { db in
            try Schema.dropProjectionTables(db)
            try Schema.createProjectionTables(db)
            try Self.replayProjections(db, projector: projector)
        }
    }
}
