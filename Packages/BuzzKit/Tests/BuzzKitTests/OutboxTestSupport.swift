@testable import BuzzKit
import Foundation
import GRDB
import NostrCore

/// A clock a test can wind forward, so age-based decisions (the stale-timestamp
/// re-sign) are exercised without touching the wall clock. `Date`-valued, unlike
/// the presence suite's monotonic `MutableClock` — the store's clock stamps
/// `created_at`, which is wall-clock by nature.
final class MutableDateClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var now: Date { lock.withLock { current } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    var reader: @Sendable () -> Date {
        { [self] in self.now }
    }
}

/// One identity and one store on a fresh temp database, wired to `clock`. Shared by
/// the two outbox test suites.
struct OutboxHarness {
    let store: BuzzEventStore
    let database: TempDatabase
    let signer: InMemorySigner
    let pubkey: String
    let clock: MutableDateClock

    init(start: TimeInterval = 1_700_000_000) throws {
        let key = try PrivateKey()
        signer = InMemorySigner(key)
        pubkey = key.publicKey.hex
        clock = MutableDateClock(Date(timeIntervalSince1970: start))
        database = TempDatabase()
        store = try BuzzEventStore(path: database.path, projector: NullProjector(), clock: clock.reader)
    }

    func remove() { database.remove() }

    /// The `state` column of a row, read raw so a test asserts persisted state
    /// rather than a value the store handed back.
    func rawState(_ eventID: String) async throws -> String? {
        try await store.reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM outbox WHERE event_id = ?",
                arguments: [eventID]
            )
        }
    }
}
