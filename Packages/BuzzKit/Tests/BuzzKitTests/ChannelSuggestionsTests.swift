@testable import BuzzKit
import NostrCore
import Testing

@Suite("Composer channel suggestions", .timeLimit(.minutes(1)))
struct ChannelSuggestionsTests {
    @Test("returns named channels by name, case-insensitively, carrying privacy")
    func namedChannelsOrderedByName() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"zebra"}"#,
                tags: [["d", "room-z"]],
                at: 1_000
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"Alpha"}"#,
                tags: [["d", "room-a"], ["private"]],
                at: 1_001
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"beta"}"#,
                tags: [["d", "room-b"]],
                at: 1_002
            ),
        ], phase: .backfill)

        let suggestions = try store.channelSuggestions()
        // NOCASE, so "Alpha" sorts before "beta" rather than after "zebra".
        #expect(suggestions.map(\.name) == ["Alpha", "beta", "zebra"])
        #expect(suggestions.map(\.id) == ["room-a", "room-b", "room-z"])
        #expect(suggestions.map(\.isPrivate) == [true, false, false])
    }

    @Test("omits a channel with no usable name instead of exposing its group id")
    func skipsNamelessChannels() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, "{}", tags: [["d", "room-nameless"]], at: 1_000),
            try relay.event(
                .groupMetadata,
                #"{"name":"   "}"#,
                tags: [["d", "room-blank"]],
                at: 1_001
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"  General  "}"#,
                tags: [["d", "room-1"]],
                at: 1_002
            ),
        ], phase: .backfill)

        let suggestions = try store.channelSuggestions()
        // The nameless and whitespace-only channels are gone, and the surviving name
        // is the trimmed one — never the group id.
        #expect(suggestions.count == 1)
        #expect(suggestions.first?.name == "General")
        #expect(suggestions.first?.id == "room-1")
    }

    @Test("follows the channel projection when metadata is replaced")
    func followsRenames() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"old-name"}"#,
                tags: [["d", "room-1"]],
                at: 1_000
            ),
        ], phase: .backfill)
        #expect(try store.channelSuggestions().map(\.name) == ["old-name"])

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"new-name"}"#,
                tags: [["d", "room-1"], ["private"]],
                at: 2_000
            ),
        ], phase: .live)

        let renamed = try store.channelSuggestions()
        #expect(renamed.map(\.name) == ["new-name"])
        #expect(renamed.first?.isPrivate == true)
    }
}
