@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What the relay calls a room, kept rather than re-derived.
///
/// A direct message of two is recognisable from its roster alone, which is how this app
/// has always found one. A direct message of four is not: it and a private channel of four
/// are the same shape from the client's side, and only the relay knows which is which —
/// so its own `["t", <type>]` is projected and carried to the surface that has to tell
/// them apart.
@Suite("Channel type", .timeLimit(.minutes(1)))
struct ChannelTypeTests {
    @Test("keeps the relay's channel type, and reads a DM as a direct message")
    func projectsChannelType() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"Group DM (3)"}"#,
                tags: [["d", "dm-3"], ["private"], ["hidden"], ["t", "dm"]],
                at: 1_000
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"General"}"#,
                tags: [["d", "general"], ["t", "stream"]],
                at: 1_000
            ),
        ], phase: .backfill)

        let rows = try store.channelList()
        let dm = try #require(rows.first { $0.id == "dm-3" })
        #expect(dm.channelType == "dm")
        #expect(dm.isDirectMessage)

        let general = try #require(rows.first { $0.id == "general" })
        #expect(general.channelType == "stream")
        #expect(!general.isDirectMessage)
    }

    /// The fallback the research note calls for: a relay deployed before the `t` tag still
    /// marks a DM with a bare `hidden`, which it pushes on that channel type and no other.
    @Test("reads a bare hidden tag as a DM when no type tag was sent")
    func hiddenStandsInForTheTypeTag() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"DM"}"#,
                tags: [["d", "old-dm"], ["private"], ["hidden"]],
                at: 1_000
            ),
        ], phase: .backfill)

        let row = try #require(try store.channelList().first { $0.id == "old-dm" })
        #expect(row.channelType == "dm")
        #expect(row.isDirectMessage)
    }

    /// A channel whose metadata says nothing about its type is a *don't know*, not a
    /// stream: reading it as one would present a guess as the relay's answer, and the two
    /// are told apart by nothing else on the wire.
    @Test("leaves the type unknown when the metadata carries neither tag")
    func untypedChannelStaysUnknown() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"Legacy"}"#,
                tags: [["d", "legacy"]],
                at: 1_000
            ),
        ], phase: .backfill)

        let row = try #require(try store.channelList().first { $0.id == "legacy" })
        #expect(row.channelType == nil)
        #expect(!row.isDirectMessage)
    }

    @Test("a later metadata event can change the type it reports")
    func typeFollowsTheNewestMetadata() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"Room"}"#,
                tags: [["d", "room"]],
                at: 1_000
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"Room"}"#,
                tags: [["d", "room"], ["t", "forum"]],
                at: 2_000
            ),
        ], phase: .backfill)

        let row = try #require(try store.channelList().first { $0.id == "room" })
        #expect(row.channelType == "forum")
    }

    /// A `#`-link names a room a reader could go and find. A DM is not one, and the only
    /// name it has to offer is the relay's placeholder — the exact string the rest of the
    /// app now refuses to render.
    @Test("keeps direct messages out of the composer's channel suggestions")
    func suggestionsExcludeDirectMessages() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"Group DM (3)"}"#,
                tags: [["d", "dm-3"], ["private"], ["hidden"], ["t", "dm"]],
                at: 1_000
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"DM"}"#,
                tags: [["d", "dm-2"], ["private"], ["hidden"], ["t", "dm"]],
                at: 1_000
            ),
            try relay.event(
                .groupMetadata,
                #"{"name":"General"}"#,
                tags: [["d", "general"], ["t", "stream"]],
                at: 1_000
            ),
            // No type tag: unknown, and unknown must not be filtered out — a store that
            // predates the tag would otherwise lose every channel from the `#` picker.
            try relay.event(
                .groupMetadata,
                #"{"name":"Legacy"}"#,
                tags: [["d", "legacy"]],
                at: 1_000
            ),
        ], phase: .backfill)

        #expect(try store.channelSuggestions().map(\.name) == ["General", "Legacy"])
    }
}
