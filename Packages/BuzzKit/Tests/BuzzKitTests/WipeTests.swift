@testable import BuzzKit
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

        // A fresh ingest after the wipe still lands — the store is not corrupted.
        let again = try fixture.message("again", in: "room-1", at: 1_700_000_100)
        _ = try await store.ingest(batch: [again], phase: .live)
        #expect(try await store.count() == 1)
    }
}
