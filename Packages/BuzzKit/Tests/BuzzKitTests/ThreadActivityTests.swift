@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The Threads screen's read: which threads have been active, what sits between their
/// opener and their newest reply, and how many are holding replies the reader has not
/// seen.
@Suite("Thread activity", .timeLimit(.minutes(1)))
struct ThreadActivityTests {
    private func meta(_ relay: Fixture, _ id: String, name: String) throws -> NostrEvent {
        try relay.event(.groupMetadata, #"{"name":"\#(name)"}"#, tags: [["d", id]], at: 100)
    }

    private func reply(
        _ author: Fixture,
        _ content: String,
        to root: NostrEvent,
        in channel: String = "room-1",
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, content,
            tags: [["h", channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }

    // MARK: - Shape

    @Test("threads include only roots or replies written by the reader")
    func filtersToReaderParticipation() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let reader = try Fixture()
        let peer = try Fixture()
        let other = try Fixture()

        let readerOpened = try reader.message("my question", in: "room-1", at: 1000)
        let replyOpened = try peer.message("their question", in: "room-1", at: 1100)
        let otherOpened = try peer.message("someone else's question", in: "room-1", at: 1200)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            readerOpened,
            try reply(peer, "their answer", to: readerOpened, at: 2000),
            replyOpened,
            try reply(reader, "my answer", to: replyOpened, at: 3000),
            otherOpened,
            try reply(other, "another answer", to: otherOpened, at: 4000),
        ], phase: .backfill)

        let activity = try store.threadActivity(selfPubkey: reader.pubkey, limit: 10)
        #expect(activity.count == 2)
        #expect(Set(activity.map(\.rootID)) == Set([readerOpened.id, replyOpened.id]))
    }

    @Test("unread threads include only roots or replies written by the reader")
    func filtersUnreadThreadsToReaderParticipation() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let reader = try Fixture()
        let peer = try Fixture()
        let other = try Fixture()

        let readerOpened = try reader.message("my question", in: "room-1", at: 1000)
        let replyOpened = try peer.message("their question", in: "room-1", at: 1100)
        let otherOpened = try peer.message("someone else's question", in: "room-1", at: 1200)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            readerOpened,
            try reply(peer, "their answer", to: readerOpened, at: 2000),
            replyOpened,
            try reply(reader, "my answer", to: replyOpened, at: 3000),
            try reply(peer, "their follow-up", to: replyOpened, at: 4000),
            otherOpened,
            try reply(other, "another answer", to: otherOpened, at: 5000),
        ], phase: .backfill)

        let unread = try store.unreadThreads(selfPubkey: reader.pubkey)
        #expect(unread.count == 2)
        #expect(Set(unread.map(\.rootID)) == Set([readerOpened.id, replyOpened.id]))
    }

    @Test("a thread carries its opener, its newest reply, and what is between them")
    func activityShape() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("the question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "first", to: opener, at: 2000),
            try reply(peer, "second", to: opener, at: 3000),
            try reply(peer, "newest", to: opener, at: 4000),
        ], phase: .backfill)

        let activity = try store.threadActivity(selfPubkey: nil, limit: 10)
        let thread = try #require(activity.first)
        #expect(thread.rootID == opener.id)
        #expect(thread.channelID == "room-1")
        #expect(thread.opener.content == "the question")
        #expect(thread.latestReply.content == "newest")
        #expect(thread.replyCount == 3)
        // Two replies sit between the opener and the newest one — the "2 more replies"
        // a row admits to rather than drawing.
        #expect(thread.intermediateReplyCount == 2)
    }

    @Test("a single-reply thread hides nothing, so it claims nothing hidden")
    func singleReplyThread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("hi", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "only", to: opener, at: 2000),
        ], phase: .backfill)

        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.replyCount == 1)
        #expect(thread.intermediateReplyCount == 0)
        #expect(thread.opener.content == "hi")
        #expect(thread.latestReply.content == "only")
    }

    @Test("a message with no replies is not a thread")
    func repliesRequired() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            try peer.message("nobody answered", in: "room-1", at: 1000),
        ], phase: .backfill)

        #expect(try store.threadActivity(selfPubkey: nil, limit: 10).isEmpty)
        #expect(try store.unreadThreads(selfPubkey: nil).isEmpty)
    }

    @Test("threads order by their newest reply, not by when they were opened")
    func ordersByLatestReply() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        // `old` was opened first and answered last; `new` the other way round. Ordering
        // on the opener would reverse these.
        let old = try peer.message("opened first", in: "room-1", at: 1000)
        let recent = try peer.message("opened second", in: "room-1", at: 2000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            old, recent,
            try reply(peer, "answering the new one", to: recent, at: 3000),
            try reply(peer, "answering the old one", to: old, at: 5000),
        ], phase: .backfill)

        let activity = try store.threadActivity(selfPubkey: nil, limit: 10)
        #expect(activity.map(\.rootID) == [old.id, recent.id])
        #expect(try store.threadActivity(selfPubkey: nil, limit: 1).map(\.rootID) == [old.id])
    }

    // MARK: - Content resolution

    @Test("an edited message reads as its edit, and a deleted reply drops out entirely")
    func resolvesContentLikeTheThreadItOpens() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("typo heer", in: "room-1", at: 1000)
        let doomed = try reply(peer, "never mind", to: opener, at: 4000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "the real newest", to: opener, at: 3000),
            doomed,
            // The author's own edit of their own opener: authorized, so it wins.
            try peer.event(
                .messageEdit, "typo here", tags: [["e", opener.id]], at: 1500
            ),
            // The author deletes their own newest reply: it stops being the newest, and
            // stops counting.
            try peer.event(.deletion, "", tags: [["e", doomed.id]], at: 4001),
        ], phase: .backfill)

        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.opener.content == "typo here")
        #expect(thread.opener.isEdited)
        #expect(thread.latestReply.content == "the real newest")
        #expect(thread.replyCount == 1)
    }

    @Test("a thread whose opener was deleted is not offered")
    func deletedOpenerDropsTheThread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("about to go", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "still here", to: opener, at: 2000),
        ], phase: .backfill)
        #expect(try store.threadActivity(selfPubkey: nil, limit: 10).count == 1)

        _ = try await store.ingest(batch: [
            try peer.event(.deletion, "", tags: [["e", opener.id]], at: 2001),
        ], phase: .live)
        #expect(try store.threadActivity(selfPubkey: nil, limit: 10).isEmpty)
        #expect(try store.unreadThreads(selfPubkey: nil).isEmpty)
    }

    // MARK: - What counts as new

    @Test("new replies are other people's, newer than the channel frontier")
    func newRepliesFollowTheFrontier() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfKey = try PrivateKey()
        let selfPubkey = selfKey.publicKey.hex

        let opener = try peer.message("question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "one", to: opener, at: 2000),
            try reply(peer, "two", to: opener, at: 3000),
            // The reader's own reply is never new to the reader.
            try NostrEvent.signed(
                kind: .channelMessage, content: "mine",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"]],
                createdAt: Date(timeIntervalSince1970: 4000), with: selfKey
            ),
        ], phase: .backfill)

        var thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.replyCount == 3)
        #expect(thread.newReplyCount == 2)
        #expect(thread.hasNewReplies)
        // The newest reply is the reader's own at 4000; the newest one a read mark can be
        // judged against is the peer's at 3000. Taking the former is the cross-device bug:
        // a mark set here would be outrun by the reader's own message.
        #expect(thread.latestReply.createdAt == 4000)
        #expect(thread.latestReplyByOthersAt == 3000)
        #expect(try store.unreadThreads(selfPubkey: selfPubkey).map(\.newReplyCount) == [2])

        // The frontier is the *channel's*: reading the channel to its end also clears its
        // threads, since NIP-RS keys read state by channel and there is no finer one.
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: ["room-1": 4000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )
        thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.newReplyCount == 0)
        #expect(!thread.hasNewReplies)
        #expect(try store.unreadThreads(selfPubkey: selfPubkey).isEmpty)
        // Still listed — the screen shows recent activity, not only unread activity.
        #expect(thread.replyCount == 3)
        // And still the peer's 3000: the frontier decides what is *new*, never who said the
        // last word. A maximum restricted to new replies would have collapsed to nothing
        // here, and a device-local mark would have had nothing left to be compared against.
        #expect(thread.latestReplyByOthersAt == 3000)
    }

    @Test("the card's read is one row per thread, not one per reply")
    func unreadThreadsAreGroupedByRoot() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let busy = try peer.message("busy", in: "room-1", at: 1000)
        let quiet = try peer.message("quiet", in: "room-1", at: 1100)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            busy, quiet,
            try reply(peer, "a", to: busy, at: 2000),
            try reply(peer, "b", to: busy, at: 2100),
            try reply(peer, "c", to: busy, at: 2200),
            try reply(peer, "d", to: quiet, at: 2300),
        ], phase: .backfill)

        // Four new replies across two threads, and two rows back: the card offers a screen
        // to go and read, and two conversations to catch up on is what someone can act on.
        // Newest activity first, and each row carries its own newest reply so a device-local
        // read mark has something to be compared against.
        let unread = try store.unreadThreads(selfPubkey: nil)
        #expect(unread.map(\.rootID) == [quiet.id, busy.id])
        #expect(unread.map(\.newReplyCount) == [1, 3])
        #expect(unread.map(\.latestReplyAt) == [2300, 2200])
        // With nothing of the reader's in either thread the two maxima coincide, which is
        // the case that hides the difference — hence the ones above that do not.
        #expect(unread.map(\.latestReplyByOthersAt) == [2300, 2200])
    }

    @Test("the reader's own reply moves the newest reply, never the one a mark is judged by")
    func latestReplyAtIncludesOwnReplies() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfKey = try PrivateKey()

        let opener = try peer.message("question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "theirs", to: opener, at: 2000),
            try NostrEvent.signed(
                kind: .channelMessage, content: "mine",
                tags: [["h", "room-1"], ["e", opener.id, "", "reply"]],
                createdAt: Date(timeIntervalSince1970: 3000), with: selfKey
            ),
        ], phase: .backfill)

        // One new reply — the peer's — but the newest reply is the reader's own, and that
        // is the timestamp a mark set from what is on screen will carry.
        let unread = try #require(try store.unreadThreads(selfPubkey: selfKey.publicKey.hex).first)
        #expect(unread.newReplyCount == 1)
        #expect(unread.latestReplyAt == 3000)
        // The two are a message apart, and that message is the reader's. A mark set at 2000
        // on the device that read this thread is *behind* `latestReplyAt` and level with
        // this — which is why the second one exists and the count is judged by it.
        #expect(unread.latestReplyByOthersAt == 2000)
    }

    @Test("a non-positive limit reads nothing")
    func limitGuard() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        #expect(try store.threadActivity(selfPubkey: nil, limit: 0).isEmpty)
    }
}
