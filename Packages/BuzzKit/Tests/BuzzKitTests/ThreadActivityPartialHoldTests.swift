@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What the Threads screen may claim about a thread it holds only part of.
///
/// # Why a partial hold is now the normal case
///
/// A bounded prefetch (``SyncEngine/prefetchThreads(in:)``) takes a thread's *newest*
/// replies and stops, so a thread larger than the budget is held in part — deliberately,
/// because the alternative grows with every reply ever written. Two of this read's numbers
/// then behave differently, and the difference is the whole of this suite:
///
/// - The **total** survives: it is composed with the relay's tally by the same rule a
///   message row's own count takes, so a thread of thirty held twenty deep still says
///   thirty. Understating it would be a worse lie than the one the prefetch fixes.
/// - **How many are new to you** cannot be composed: it is arithmetic over individual
///   replies' authors and times, and the tally carries neither
///   (`ThreadSummaryPayload` decodes three integers). So it is counted over what is held
///   and may be short.
///
/// Short only in one arrangement, though. A prefetch holds the newest replies, so once the
/// reader's frontier falls anywhere *inside* them, every reply past it is here and the count
/// is exact however much older history is missing. It is a floor only when the oldest held
/// reply is still newer than the frontier. Getting that boundary wrong in the conservative
/// direction is not free either — it would mark an exact count as approximate on most of
/// the threads anybody reads.
@Suite("A thread held in part", .timeLimit(.minutes(1)))
struct ThreadActivityPartialHoldTests {
    private static let channel = "room-1"

    private func meta(_ relay: Fixture) throws -> NostrEvent {
        try relay.event(.groupMetadata, #"{"name":"One"}"#, tags: [["d", Self.channel]], at: 100)
    }

    private func reply(
        _ author: Fixture,
        _ content: String,
        to root: NostrEvent,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, content,
            tags: [["h", Self.channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }

    private func summary(
        for root: String,
        descendantCount: Int,
        lastReplyAt: Int64,
        from relay: Fixture
    ) throws -> NostrEvent {
        let content = """
        {"reply_count":\(descendantCount),"descendant_count":\(descendantCount),\
        "last_reply_at":\(lastReplyAt),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", Self.channel]], at: 1_700_000_500
        )
    }

    // MARK: - The total

    @Test("a thread held in part still reports the relay's total")
    func theTotalComesFromTheRelay() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 30, lastReplyAt: 4_000, from: relay),
            // The two newest of thirty — what a prefetch clipped at 2 would leave behind.
            try reply(peer, "second newest", to: opener, at: 3_000),
            try reply(peer, "newest", to: opener, at: 4_000),
        ], phase: .backfill)

        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.replyCount == 30)
        // And the row still knows which message is the newest one, which is what it draws.
        #expect(thread.latestReply.content == "newest")
        #expect(thread.intermediateReplyCount == 29)
    }

    @Test("opening the thread makes this device's own total the later word")
    func openingTheThreadSettlesTheTotal() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 30, lastReplyAt: 4_000, from: relay),
            try reply(peer, "the only survivor", to: opener, at: 4_000),
        ], phase: .backfill)
        #expect(try store.threadActivity(selfPubkey: nil, limit: 10).first?.replyCount == 30)

        // The reader opens it, and this device now holds the thread: the other twenty-nine
        // were withdrawn and that correction never arrived. A count that could only go up
        // would advertise them forever.
        try await store.recordThreadFetch(root: opener.id)

        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.replyCount == 1)
    }

    @Test("a thread with no relay tally counts only what is held")
    func withoutATallyTheLocalCountStands() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try reply(peer, "one", to: opener, at: 2_000),
            try reply(peer, "two", to: opener, at: 3_000),
        ], phase: .backfill)

        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.replyCount == 2)
        #expect(thread.newReplyCountIsExact)
    }

    // MARK: - How many are new

    /// The floor case: every reply this device holds is unread, so unread replies may lie
    /// below the window as well and how many is unanswerable here.
    @Test("the unread count is a floor when the frontier is below everything held")
    func aFrontierBelowTheWindowMakesTheCountAFloor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 30, lastReplyAt: 4_000, from: relay),
            try reply(peer, "second newest", to: opener, at: 3_000),
            try reply(peer, "newest", to: opener, at: 4_000),
        ], phase: .backfill)
        // Read up to the opener and no further: both held replies are past the frontier.
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: [Self.channel: 1_000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        let thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.newReplyCount == 2)
        #expect(thread.newReplyCountIsExact == false)
    }

    /// The exact case, and the reason the test is about *time* rather than completeness:
    /// this device holds two of thirty replies and the frontier sits between them, so
    /// "one new" is the whole answer — everything newer than the frontier is here.
    @Test("the unread count is exact when the frontier falls inside what is held")
    func aFrontierInsideTheWindowIsExact() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 30, lastReplyAt: 4_000, from: relay),
            try reply(peer, "read", to: opener, at: 3_000),
            try reply(peer, "unread", to: opener, at: 4_000),
        ], phase: .backfill)
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: [Self.channel: 3_000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        let thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.newReplyCount == 1)
        #expect(thread.newReplyCountIsExact)
    }

    /// A thread this device holds completely is exact whatever the frontier says, so the
    /// ordinary opened thread never carries the qualification.
    @Test("a thread held in full is always exact")
    func aCompleteHoldIsExact() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 2, lastReplyAt: 4_000, from: relay),
            try reply(peer, "one", to: opener, at: 3_000),
            try reply(peer, "two", to: opener, at: 4_000),
        ], phase: .backfill)
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: [Self.channel: 1_000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        let thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.newReplyCount == 2)
        #expect(thread.newReplyCountIsExact)
    }

    /// A floor of zero is not a floor. Everything held is read, and since the held replies
    /// are the *newest* ones, nothing below them can be unread either — so the answer is
    /// exactly none, and a thread that says so is a thread that stays off the screen.
    @Test("nothing unread among the newest replies means nothing unread at all")
    func zeroIsNeverAFloor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let selfPubkey = try PrivateKey().publicKey.hex

        let opener = try peer.message("the question", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [
            try meta(relay),
            opener,
            try summary(for: opener.id, descendantCount: 30, lastReplyAt: 4_000, from: relay),
            try reply(peer, "read", to: opener, at: 3_000),
            try reply(peer, "also read", to: opener, at: 4_000),
        ], phase: .backfill)
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: [Self.channel: 5_000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        let thread = try #require(try store.threadActivity(selfPubkey: selfPubkey, limit: 10).first)
        #expect(thread.newReplyCount == 0)
        #expect(thread.newReplyCountIsExact)
        // And nothing about the partial hold resurfaces it in the sidebar's count.
        #expect(try store.unreadThreads(selfPubkey: selfPubkey).isEmpty)
    }
}
