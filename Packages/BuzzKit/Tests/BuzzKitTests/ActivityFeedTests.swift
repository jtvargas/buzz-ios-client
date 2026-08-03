@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The Activity feed read: which events reach the screen, how they collapse into
/// conversations, and what the counts on a row mean.
///
/// The grouping is the whole reason this exists — the Flutter client renders one row per
/// event, which is what makes nine replies in one thread read as nine things to deal with —
/// so most of what is pinned here is "these N events become one row saying M".
@Suite("Activity feed", .timeLimit(.minutes(1)))
struct ActivityFeedTests {
    // MARK: - Grouping

    @Test("collapses every reply in one thread into a single row carrying the count")
    func groupsThreadRepliesIntoOneRow() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let agent = try Fixture()

        // The shape JT photographed: one thread, many replies, each naming him.
        let opener = try ActivityFixtures.message(agent, "starting", in: "room-1", mentions: [me], at: 1000)
        let replies = try (1 ... 8).map { index in
            try ActivityFixtures.message(
                agent, "reply \(index)", in: "room-1",
                mentions: [me], replyTo: opener.id, at: 1000 + Int64(index) * 10
            )
        }
        _ = try await store.ingest(
            batch: [try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500), opener] + replies,
            phase: .backfill
        )

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.count == 1, "nine events in one thread are one conversation, not nine rows")
        let row = try #require(feed.first)
        #expect(row.eventCount == 9)
        #expect(row.rootID == opener.id)
        #expect(row.latest.content == "reply 8", "the row draws the newest event")
        #expect(row.category == .mention)
    }

    @Test("keeps two separate top-level mentions as two rows")
    func separateTopLevelMentionsStaySeparate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        // Two unrelated asks in the same channel really are two things to deal with. This
        // is the boundary of the grouping: it collapses a conversation, never a channel.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.message(author, "first ask", in: "room-1", mentions: [me], at: 1000),
            try ActivityFixtures.message(author, "second ask", in: "room-1", mentions: [me], at: 2000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.count == 2)
        #expect(feed.map(\.latest.content) == ["second ask", "first ask"], "newest first")
        #expect(feed.allSatisfy { $0.eventCount == 1 })
    }

    @Test("groups a direct message conversation by its channel, however it is threaded")
    func groupsDirectMessagesByChannel() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["dm-1"])
        let relay = try Fixture()
        let peer = try Fixture()

        // No `p` tag anywhere: a DM never needs to name you, the channel is the address.
        // If the feed required one, direct messages would silently never appear.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "dm-1", name: "dm", type: "dm", at: 500),
            try ActivityFixtures.message(peer, "hey", in: "dm-1", at: 1000),
            try ActivityFixtures.message(peer, "you around?", in: "dm-1", at: 2000),
            try ActivityFixtures.message(peer, "nvm", in: "dm-1", at: 3000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.count == 1)
        let row = try #require(feed.first)
        #expect(row.isDirectMessage)
        #expect(row.eventCount == 3)
        #expect(row.latest.content == "nvm")
        #expect(row.category == .activity, "a DM is not a mention unless it names you")
    }

    // MARK: - What qualifies

    @Test("excludes your own messages, and channel traffic that has nothing to do with you")
    func excludesOwnAndUnrelated() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let mine = try Fixture()
        let me = mine.pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let stranger = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            // Names me, but I wrote it — talking about yourself is not news.
            try ActivityFixtures.message(mine, "my own post", in: "room-1", mentions: [me], at: 1000),
            // Someone else's chatter in a channel I am in, naming nobody. This is the
            // firehose the screen deliberately does not carry.
            try ActivityFixtures.message(stranger, "unrelated chatter", in: "room-1", at: 2000),
        ], phase: .backfill)

        #expect(try store.activityFeed(selfPubkey: me, limit: 50).isEmpty)
    }

    @Test("carries a reply in a thread you spoke in, even when it does not name you")
    func carriesRepliesInThreadsYouAreIn() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let mine = try Fixture()
        let me = mine.pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()
        let other = try Fixture()

        let opener = try ActivityFixtures.message(author, "question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            opener,
            try ActivityFixtures.message(mine, "my answer", in: "room-1", replyTo: opener.id, at: 2000),
            // Lands after I spoke, names nobody. It is still mine to see: I am in this
            // conversation, and this is the case a `p`-tag-only feed drops on the floor.
            try ActivityFixtures.message(other, "a follow-up", in: "room-1", replyTo: opener.id, at: 3000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        let row = try #require(feed.first)
        #expect(row.rootID == opener.id)
        #expect(row.latest.content == "a follow-up")
        #expect(row.category == .activity)
        // One, not three. `eventCount` counts what in this conversation is addressed to
        // *you*, which is the number the row's "+N more" is about — so it excludes my own
        // reply, and excludes the opener too: a top-level message that named nobody and
        // that I had not yet answered was never mine to see. It became my conversation when
        // I spoke in it, and what I have to catch up on is what arrived after that.
        #expect(row.eventCount == 1)
    }

    @Test("drops a channel this identity is no longer in")
    func dropsInaccessibleChannels() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        // `left` is deliberately never marked active: the same gate the sidebar applies.
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["stays"])
        let relay = try Fixture()
        let author = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "stays", name: "Stays", at: 500),
            try ActivityFixtures.meta(relay, "left", name: "Left", at: 500),
            try ActivityFixtures.message(author, "still here", in: "stays", mentions: [me], at: 1000),
            try ActivityFixtures.message(author, "gone", in: "left", mentions: [me], at: 2000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.map(\.latest.content) == ["still here"])
    }

    @Test("yields nothing without a local identity rather than a stranger's feed")
    func requiresAnIdentity() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let author = try Fixture()
        let someone = try Fixture().pubkey

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.message(author, "for someone", in: "room-1", mentions: [someone], at: 1000),
        ], phase: .backfill)

        #expect(try store.activityFeed(selfPubkey: nil, limit: 50).isEmpty)
        #expect(try store.activityFeed(selfPubkey: "", limit: 50).isEmpty)
    }
}
