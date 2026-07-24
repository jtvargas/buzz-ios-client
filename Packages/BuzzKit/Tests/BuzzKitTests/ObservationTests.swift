@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

@Suite("Event-log observation", .timeLimit(.minutes(1)))
struct ObservationTests {
    @Test("ValueObservation fires when ingest inserts an event")
    func firesOnIngest() async throws {
        // Proves the rowid rule end to end: SQLite's update hook fires for the
        // `event` table, so GRDB notices the insert and delivers a fresh value.
        // Were the table WITHOUT ROWID, the hook would stay silent, the second
        // `next()` would never resume, and the suite's time limit would fail it.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let observation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event") ?? 0
        }
        var iterator = observation.values(in: store.reader).makeAsyncIterator()

        // The initial snapshot: an empty log.
        let initial = try await iterator.next()
        #expect(initial == 0)

        _ = try await store.ingest(batch: [fixture.message("live")], phase: .live)

        let afterInsert = try await iterator.next()
        #expect(afterInsert == 1)
    }
}
