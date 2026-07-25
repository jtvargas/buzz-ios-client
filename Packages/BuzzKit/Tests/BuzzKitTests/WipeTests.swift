@testable import BuzzKit
import GRDB
import NostrCore
import Testing

/// ``BuzzEventStore/wipe()`` clears the log and its projections for an identity
/// change, and the store stays usable afterwards.
@Suite struct WipeTests {
    @Test func wipeClearsLogAndProjectionsAndStaysUsable() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        let message = try fixture.message("hi", in: "room-1")
        let profile = try fixture.event(.metadata, #"{"name":"Bob"}"#)
        _ = try await store.ingest(batch: [message, profile], phase: .live)

        #expect(try await store.count() == 2)
        #expect(try store.profile(pubkey: fixture.pubkey) != nil)

        try await store.wipe()

        #expect(try await store.count() == 0)
        #expect(try store.profile(pubkey: fixture.pubkey) == nil)

        // A fresh ingest after the wipe still lands — the store is not corrupted
        // (which also proves the VACUUM left a usable database).
        let again = try fixture.message("again", in: "room-1", at: 1_700_000_100)
        _ = try await store.ingest(batch: [again], phase: .live)
        #expect(try await store.count() == 1)
    }

    @Test func wipeClearsReadStateAndPreservesMeta() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()

        _ = try await store.ingest(batch: [try fixture.message("hi", in: "room-1")], phase: .live)
        try await store.applyReadState(
            author: fixture.pubkey,
            slot: "slot-1",
            contexts: ["room-1": 1_700_000_000],
            sourceCreatedAt: 1_700_000_050,
            sourceEventID: String(repeating: "a", count: 64)
        )

        let versionBefore = try metaVersion(store)
        #expect(versionBefore == String(Schema.projectionVersion))
        #expect(try readStateCount(store) == 1)

        try await store.wipe()

        // The precious local read state is cleared, but the projection version is
        // preserved so the wipe never triggers a spurious rebuild.
        #expect(try readStateCount(store) == 0)
        #expect(try metaVersion(store) == versionBefore)
        #expect(try await store.count() == 0)
    }

    private func readStateCount(_ store: BuzzEventStore) throws -> Int {
        try store.reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM read_state") ?? -1
        }
    }

    private func metaVersion(_ store: BuzzEventStore) throws -> String? {
        try store.reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [Schema.projectionVersionKey]
            )
        }
    }
}
