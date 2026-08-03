@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// How the Activity feed classifies a conversation, counts what is unread in it, and bounds
/// how much of the log it will look at. Split from ``ActivityFeedTests`` — which pins the
/// grouping itself — only because one struct holding both is past the length the linter
/// allows.
@Suite("Activity feed classification", .timeLimit(.minutes(1)))
struct ActivityFeedCategoryTests {
    // MARK: - Categories

    @Test("files an agent job report under Agent and an approval under Action")
    func categorisesByKind() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let agent = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try agent.event(
                EventKind(rawValue: 43006), "the job failed",
                tags: [["h", "room-1"], ["p", me]], at: 1000
            ),
            try agent.event(
                EventKind(rawValue: 46010), "approve?",
                tags: [["h", "room-1"], ["p", me]], at: 2000
            ),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.map(\.category) == [.needsAction, .agentActivity])
        #expect(ActivityKinds.headline(forKind: 43006) == "Job failed")
        #expect(ActivityKinds.headline(forKind: 46010) == "Approval requested")
    }

    @Test("a conversation mixing categories wears the loudest and matches every one")
    func mixedGroupWearsLoudestCategory() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let mine = try Fixture()
        let me = mine.pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()
        let other = try Fixture()

        // A thread that names me once and then carries on without naming me. Both kinds of
        // event are mine to see, by two different routes — the `p` tag, and my having
        // spoken — and they classify differently, which is the mix worth pinning.
        let opener = try ActivityFixtures.message(author, "naming you", in: "room-1", mentions: [me], at: 1000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            opener,
            try ActivityFixtures.message(mine, "on it", in: "room-1", replyTo: opener.id, at: 1500),
            // The loudest event is deliberately NOT the newest: a mention buried under
            // later chatter must not stop the row reading as a mention.
            try ActivityFixtures.message(
                author, "still you", in: "room-1", mentions: [me], replyTo: opener.id, at: 2000
            ),
            try ActivityFixtures.message(other, "and one more", in: "room-1", replyTo: opener.id, at: 3000),
        ], phase: .backfill)

        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.category == .mention, "the loudest category present, not the newest event's")
        #expect(row.categories == [.mention, .activity], "loudest first")
        #expect(row.matches(.mention), "it must still appear under the Mentions chip")
        #expect(row.matches(.activity), "and under Activity, which is what its newest event is")
        #expect(!row.matches(.needsAction))
        #expect(row.latest.content == "and one more", "while still drawing the newest event")
    }

    @Test("an approval request is its own row, because no non-message kind can join a thread")
    func approvalsNeverJoinAThread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let agent = try Fixture()

        let opener = try ActivityFixtures.message(agent, "naming you", in: "room-1", mentions: [me], at: 1000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            opener,
            // Carries a NIP-10 reply tag pointing into the thread above, and is still not
            // in it: `BuzzProjector.project` routes only `.channelMessage` to
            // `projectThread`, so no other kind ever gets a `thread` row. Pinned because it
            // is invisible from this read's own SQL and would otherwise be rediscovered by
            // someone debugging why an approval did not collapse into the conversation it
            // names. It is also the right outcome — an approval is its own thing to action.
            try agent.event(
                EventKind(rawValue: 46010), "approve?",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"], ["p", me]], at: 2000
            ),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.count == 2)
        let approval = try #require(feed.first)
        #expect(approval.category == .needsAction)
        #expect(approval.rootID == nil)
        #expect(approval.eventCount == 1)
    }

    // MARK: - Unread

    @Test("counts only what is past the channel's read frontier")
    func countsUnreadAgainstTheFrontier() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        let opener = try ActivityFixtures.message(author, "one", in: "room-1", mentions: [me], at: 1000)
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            opener,
            try ActivityFixtures.message(author, "two", in: "room-1", mentions: [me], replyTo: opener.id, at: 2000),
            try ActivityFixtures.message(author, "three", in: "room-1", mentions: [me], replyTo: opener.id, at: 3000),
        ], phase: .backfill)

        // Nothing has ever been marked read: unknown state is unread, the conservative
        // NIP-RS default, and the same one the sidebar's badge takes.
        var row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.unreadCount == 3)
        #expect(row.isUnread)

        // Read up to and including "two". Only "three" is left.
        try await store.applyReadState(
            author: me, slot: "slot-a", contexts: ["room-1": 2000],
            sourceCreatedAt: 2500, sourceEventID: String(repeating: "a", count: 64)
        )
        row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.unreadCount == 1)
        #expect(row.eventCount == 3, "reading something does not remove it from the conversation")

        try await store.applyReadState(
            author: me, slot: "slot-a", contexts: ["room-1": 9000],
            sourceCreatedAt: 9500, sourceEventID: String(repeating: "b", count: 64)
        )
        row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.unreadCount == 0)
        #expect(!row.isUnread, "a fully-read conversation still shows, it just stops shouting")
    }

    @Test("a lone top-level mention still reports its own unread state")
    func singletonRowsCarryUnreadState() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.message(author, "just you", in: "room-1", mentions: [me], at: 1000),
        ], phase: .backfill)

        // Desktop cannot answer this: `unreadCount` is hardcoded to 0 for any row with no
        // thread replies and no DM channel (`inbox.ts:602-628` — every branch that counts
        // requires one or the other), so its badge is blind to exactly the commonest case
        // there is. Hive counts against the channel frontier, which every row has.
        let row = try #require(try store.activityFeed(selfPubkey: me, limit: 50).first)
        #expect(row.eventCount == 1)
        #expect(row.unreadCount == 1)
        #expect(row.isUnread)
    }

    // MARK: - Bounds

    @Test("the row limit bounds conversations, and a busy thread cannot crowd the rest out")
    func limitBoundsConversationsNotEvents() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        // One thread with forty replies, then three separate mentions after it. A read that
        // capped *events* at the row count would return the loud thread and nothing else.
        let opener = try ActivityFixtures.message(author, "loud thread", in: "room-1", mentions: [me], at: 1000)
        let replies = try (1 ... 40).map { index in
            try ActivityFixtures.message(
                author, "noise \(index)", in: "room-1",
                mentions: [me], replyTo: opener.id, at: 1000 + Int64(index)
            )
        }
        let separate = try (1 ... 3).map { index in
            try ActivityFixtures.message(author, "ask \(index)", in: "room-1", mentions: [me], at: 5000 + Int64(index))
        }
        _ = try await store.ingest(
            batch: [try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500), opener] + replies + separate,
            phase: .backfill
        )

        let feed = try store.activityFeed(selfPubkey: me, limit: 3)
        #expect(feed.count == 3)
        #expect(feed.map(\.latest.content) == ["ask 3", "ask 2", "ask 1"])
        #expect(try store.activityFeed(selfPubkey: me, limit: 0).isEmpty)

        // Unbounded, the loud thread is one row that knows how loud it was.
        let full = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(full.count == 4)
        #expect(full.last?.eventCount == 41)
    }

    // MARK: - Identity matching

    @Test("matches a mention tag whose key another client upper-cased")
    func matchesMentionTagCaseInsensitively() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1"])
        let relay = try Fixture()
        let author = try Fixture()

        // A tag value is a raw string written by whichever client sent the message and is
        // never decoded on the way in. Missing a mention because of its case is the worse
        // failure, which is why the tag join is `COLLATE NOCASE`.
        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.message(author, "shouted key", in: "room-1", mentions: [me.uppercased()], at: 1000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        #expect(feed.map(\.latest.content) == ["shouted key"])
        #expect(feed.first?.category == .mention)
        // And the caller's own casing must not matter either.
        #expect(try store.activityFeed(selfPubkey: me.uppercased(), limit: 50).count == 1)
    }

    // MARK: - Author resolution

    @Test("resolves the author's name and avatar in the read, falling back to the key")
    func resolvesAuthors() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let me = try Fixture().pubkey
        let store = try await ActivityFixtures.openStore(database, identity: me, channels: ["room-1", "room-2"])
        let relay = try Fixture()
        let named = try Fixture()
        let anon = try Fixture()

        _ = try await store.ingest(batch: [
            try ActivityFixtures.meta(relay, "room-1", name: "Room", at: 500),
            try ActivityFixtures.meta(relay, "room-2", name: "Other", at: 500),
            try named.event(.metadata, #"{"display_name":"Alice","picture":"https://x/a.png"}"#, at: 900),
            try ActivityFixtures.message(named, "from alice", in: "room-1", mentions: [me], at: 1000),
            try ActivityFixtures.message(anon, "from a stranger", in: "room-2", mentions: [me], at: 2000),
        ], phase: .backfill)

        let feed = try store.activityFeed(selfPubkey: me, limit: 50)
        let stranger = try #require(feed.first { $0.channelID == "room-2" })
        let alice = try #require(feed.first { $0.channelID == "room-1" })

        #expect(alice.latest.authorName == "Alice")
        #expect(alice.latest.authorPicture == "https://x/a.png")
        #expect(alice.channelName == "Room")
        // Never blank: shortening a bare key for display is the row's business, but the
        // read must not hand the row an empty string to draw.
        #expect(stranger.latest.authorName == anon.pubkey)
        #expect(stranger.latest.authorPicture == nil)
    }
}
