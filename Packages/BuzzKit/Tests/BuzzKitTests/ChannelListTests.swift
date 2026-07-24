@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

@Suite("Channel list", .timeLimit(.minutes(1)))
struct ChannelListTests {
    // MARK: - Metadata, ordering, and NULLS LAST

    @Test("lists channels with metadata, newest-active first and messageless last")
    func listsChannelsOrdered() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "general", name: "General", about: "the main room",
                     picture: "https://x/pic", at: 500),
            try meta(relay, "random", name: "Random", private: true, at: 500),
            // Alphabetically first yet messageless, so it must still sort *below*
            // every channel that has a message — proving NULLS LAST dominates name.
            try meta(relay, "aaa-empty", name: "Aardvark", at: 500),
            try meta(relay, "zzz-empty", name: "Zed", at: 500),
            author.message("hey general", in: "general", at: 1000),
            author.message("hi random", in: "random", at: 2000),
        ], phase: .backfill)

        let rows = try store.channelList()
        #expect(rows.map(\.id) == ["random", "general", "aaa-empty", "zzz-empty"])

        let random = try #require(rows.first { $0.id == "random" })
        #expect(random.name == "Random")
        #expect(random.isPrivate)
        #expect(random.lastMessageSnippet == "hi random")
        #expect(random.lastMessageAt == 2000)

        let general = try #require(rows.first { $0.id == "general" })
        #expect(general.name == "General")
        #expect(general.about == "the main room")
        #expect(general.picture == "https://x/pic")
        #expect(!general.isPrivate)
        #expect(general.lastMessageSnippet == "hey general")

        // A messageless channel carries metadata but a null last-message preview,
        // and the two of them keep their alphabetical order at the tail.
        let empties = rows.suffix(2)
        #expect(empties.map(\.id) == ["aaa-empty", "zzz-empty"])
        for empty in empties {
            #expect(empty.lastMessageAt == nil)
            #expect(empty.lastMessageSnippet == nil)
            #expect(empty.lastMessageAuthor == nil)
        }
    }

    // MARK: - Author resolution

    @Test("last-message author is the profile name when known, else the raw pubkey")
    func resolvesAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let named = try Fixture()
        let anon = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "known", name: "Known", at: 500),
            try meta(relay, "unknown", name: "Unknown", at: 500),
            named.event(.metadata, #"{"display_name":"Alice"}"#, at: 900),
            named.message("from alice", in: "known", at: 1000),
            anon.message("from a stranger", in: "unknown", at: 1000),
        ], phase: .backfill)

        let rows = try store.channelList()
        let known = try #require(rows.first { $0.id == "known" })
        let unknown = try #require(rows.first { $0.id == "unknown" })

        #expect(known.lastMessageAuthor == "Alice")
        #expect(unknown.lastMessageAuthor == anon.pubkey)
    }

    // MARK: - Deletion authority

    @Test("an authorized deletion of the newest message falls back to the previous one")
    func deletedNewestFallsBack() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()
        let newest = try author.message("newest", in: "room-1", at: 2000)

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Room", at: 500),
            author.message("older", in: "room-1", at: 1000),
            newest,
        ], phase: .backfill)

        #expect(try store.channelList().first?.lastMessageSnippet == "newest")

        // The author deletes their own newest message: authorized, so it drops out
        // of the visible set and the message before it becomes the preview.
        _ = try await store.ingest(batch: [
            author.event(.deletion, "", tags: [["e", newest.id]], at: 2001),
        ], phase: .live)

        let row = try #require(try store.channelList().first)
        #expect(row.lastMessageSnippet == "older")
        #expect(row.lastMessageAt == 1000)
    }

    // MARK: - Optimistic outbox

    @Test("a pending outbox send newer than the log previews optimistically without double-counting")
    func optimisticOutboxSend() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Room", at: 500),
            author.message("logged", in: "room-1", at: 1000),
        ], phase: .backfill)

        let pending = try author.message("optimistic", in: "room-1", at: 2000)
        try await store.enqueueForTest(pending, channel: "room-1")

        let optimistic = try #require(try store.channelList().first)
        #expect(optimistic.lastMessageSnippet == "optimistic")
        #expect(optimistic.lastMessageAt == 2000)

        // The relay echoes it back into the log while the outbox row still exists.
        // The log copy must win and the outbox copy must be excluded, not summed
        // into a second preview: still exactly one channel, still one preview.
        _ = try await store.ingest(batch: [pending], phase: .live)
        #expect(try await store.rowCount("outbox") == 1)

        let settled = try store.channelList()
        #expect(settled.count == 1)
        #expect(settled.first?.lastMessageSnippet == "optimistic")
        #expect(settled.first?.lastMessageAt == 2000)
    }

    // MARK: - Live observation

    @Test("ValueObservation fires when a new message arrives for a listed channel")
    func observationFiresOnNewMessage() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Room", at: 500),
            author.message("first", in: "room-1", at: 1000),
        ], phase: .backfill)

        let observation = ValueObservation.tracking { db in
            try BuzzEventStore.fetchChannelList(db)
        }
        var iterator = observation.values(in: store.reader).makeAsyncIterator()

        let initial = try await iterator.next()
        #expect(initial?.first?.lastMessageSnippet == "first")

        _ = try await store.ingest(batch: [
            author.message("second", in: "room-1", at: 2000),
        ], phase: .live)

        let afterInsert = try await iterator.next()
        #expect(afterInsert?.first?.lastMessageSnippet == "second")
    }

    // MARK: - Staleness

    @Test("a staler channel-metadata event does not clobber newer metadata through the list")
    func stalerMetadataDoesNotClobber() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "New", at: 2000),
        ], phase: .backfill)
        // An older metadata resend arriving after the newer one must be ignored.
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Old", at: 1000),
        ], phase: .live)

        #expect(try store.channelList().first?.name == "New")
    }

    // MARK: - Helpers

    /// A kind-39000 channel-metadata event, relay-signed, addressable by its `d`.
    private func meta(
        _ relay: Fixture,
        _ id: String,
        name: String,
        about: String? = nil,
        picture: String? = nil,
        private isPrivate: Bool = false,
        at seconds: Int64
    ) throws -> NostrEvent {
        var content: [String: String] = ["name": name]
        if let about { content["about"] = about }
        if let picture { content["picture"] = picture }
        let data = try JSONSerialization.data(withJSONObject: content)
        // JSONSerialization always emits UTF-8, so the fallback is unreachable; the
        // failable initializer keeps it honest, matching the store's test helpers.
        let json = String(bytes: data, encoding: .utf8) ?? "{}"

        var tags: [[String]] = [["d", id]]
        if isPrivate { tags.append(["private"]) }
        return try relay.event(.groupMetadata, json, tags: tags, at: seconds)
    }
}
