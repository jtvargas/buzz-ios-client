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
            #expect(empty.lastMessageID == nil)
            #expect(empty.lastMessageSnippet == nil)
            #expect(empty.lastMessageAuthor == nil)
            #expect(empty.lastMessageAuthorPubkey == nil)
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

        // The key comes back either way, so a caller that wants to resolve the author
        // through its own name chain never has to guess whether the column above holds a
        // name or a key — telling those apart by shape mis-reads a display name that
        // happens to be 64 hex characters.
        #expect(known.lastMessageAuthorPubkey == named.pubkey)
        #expect(unknown.lastMessageAuthorPubkey == anon.pubkey)
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
        #expect(optimistic.lastMessageID == pending.id)

        // The relay echoes it back into the log while the outbox row still exists.
        // The log copy must win and the outbox copy must be excluded, not summed
        // into a second preview: still exactly one channel, still one preview.
        _ = try await store.ingest(batch: [pending], phase: .live)
        #expect(try await store.rowCount("outbox") == 1)

        let settled = try store.channelList()
        #expect(settled.count == 1)
        #expect(settled.first?.lastMessageSnippet == "optimistic")
        #expect(settled.first?.lastMessageAt == 2000)
        #expect(settled.first?.lastMessageID == pending.id)
    }

    // MARK: - Which message is "newest"

    /// The preview is the maximum on the `(created_at, id)` keyset, and the log side of
    /// that comparison is bounded to one row before the queue is consulted (see
    /// ``newestVisibleInChannel``). A bound that keeps the wrong row of a tied second does
    /// not fail — it previews a real message that is simply not the newest one, which is
    /// the failure this pins.
    ///
    /// Event ids are hashes, so the winner cannot be chosen; it is derived from the ids
    /// the fixture produced, which is the one assertion the hashes cannot skew.
    @Test("a second holding several messages is broken by id, not by arrival")
    func previewBreaksTiesWithinTheLog() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()

        let tied = try (0 ..< 3).map { try author.message("tied-\($0)", in: "room-1", at: 2000) }
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Room", at: 500),
            author.message("older", in: "room-1", at: 1000),
        ] + tied, phase: .backfill)

        let winner = try #require(tied.max { $0.id < $1.id })
        let row = try #require(try store.channelList().first { $0.id == "room-1" })
        #expect(row.lastMessageID == winner.id)
        #expect(row.lastMessageAt == 2000)
    }

    /// The same tie across the union: one log row and one pending send sharing a second.
    ///
    /// Both directions, because only one of them is interesting per fixture and which one
    /// depends on hashes. `room-1` gives the log the greater id and `room-2` gives it to
    /// the queue, so a comparison that always prefers one side — or that drops the id
    /// tiebreak and takes whichever branch it read first — is wrong in one of the two.
    @Test("a log row and a pending send tied on a second are separated by id, either way")
    func previewBreaksTiesAcrossTheQueue() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()

        let inRoom1 = try (0 ..< 2)
            .map { try author.message("tie-\($0)", in: "room-1", at: 2000) }
            .sorted { $0.id < $1.id }
        let inRoom2 = try (0 ..< 2)
            .map { try author.message("tie-\($0)", in: "room-2", at: 2000) }
            .sorted { $0.id < $1.id }

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One", at: 500),
            try meta(relay, "room-2", name: "Two", at: 500),
            inRoom1[1],     // the log holds the greater id here
            inRoom2[0],     // and the lesser one here
        ], phase: .backfill)
        try await store.enqueueForTest(inRoom1[0], channel: "room-1")
        try await store.enqueueForTest(inRoom2[1], channel: "room-2")

        let rows = try store.channelList()
        #expect(try #require(rows.first { $0.id == "room-1" }).lastMessageID == inRoom1[1].id)
        #expect(try #require(rows.first { $0.id == "room-2" }).lastMessageID == inRoom2[1].id)
    }

    /// The preview and the unread count disagree about thread replies, deliberately.
    ///
    /// A reply the reader can see in the channel *is* the newest thing in it, so the
    /// sidebar previews it. It does not raise the channel's unread count, because a reply
    /// carries its own thread badge and counting it twice is what the two badges are for.
    /// Nothing else in either suite separates the two rules, so a `NOT EXISTS (thread …)`
    /// added to the preview — or dropped from the count — would otherwise ship green.
    @Test("a thread reply can be the preview, and still never the unread count")
    func previewIncludesRepliesTheCountExcludes() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfKey = try PrivateKey()

        let opener = try peer.message("opener", in: "room-1", at: 1000)
        let reply = try peer.event(
            .channelMessage, "a reply",
            tags: [["h", "room-1"], ["e", opener.id, "", "reply"]], at: 2000
        )
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "Room", at: 500), opener, reply,
        ], phase: .backfill)
        try await store.markChannelAccess(
            identity: selfKey.publicKey.hex,
            channel: "room-1",
            state: .active
        )

        let row = try #require(
            try store.channelList(selfPubkey: selfKey.publicKey.hex).first { $0.id == "room-1" }
        )
        #expect(row.lastMessageID == reply.id)
        #expect(row.lastMessageSnippet == "a reply")
        #expect(row.unreadCount == 1, "the opener, and not the reply under it")
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
