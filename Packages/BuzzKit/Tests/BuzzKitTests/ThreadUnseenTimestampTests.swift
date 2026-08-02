@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The timestamp a device-local read mark is judged against: the newest reply somebody
/// *other than the reader* wrote.
///
/// Split from ``ThreadActivityTests`` only for length — these are the same read, exercised
/// on the cases where "the newest reply" and "the newest reply that is not mine" come apart.
/// That gap is the whole point of the field: a mark is *set* from the newest reply the reader
/// had on screen, which is very often their own, so comparing a mark against the newest reply
/// overall lets the reader's own message push a thread they have already read back into the
/// Threads count. Every case below is one shape of that gap, or one of its edges.
@Suite("Thread activity: whose reply was last", .timeLimit(.minutes(1)))
struct ThreadUnseenTimestampTests {
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

    @Test("a thread only the reader has replied in has nothing to be behind on, and is not unread")
    func ownRepliesOnlyLeaveNothingToBeBehindOn() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let opener = try peer.message("question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(reader, "thinking", to: opener, at: 2000),
            try reply(reader, "and again", to: opener, at: 3000),
        ], phase: .backfill)

        let thread = try #require(
            try store.threadActivity(selfPubkey: reader.pubkey, limit: 10).first
        )
        #expect(thread.replyCount == 2)
        #expect(thread.newReplyCount == 0)
        #expect(thread.latestReply.createdAt == 3000)
        // `nil`, not `0`. Nobody else has said anything, so there is no timestamp to be
        // behind — and `0` would answer that only by accident, comparing as "seen" because
        // a read mark happens never to be zero. The absent case is spelled absent.
        #expect(thread.latestReplyByOthersAt == nil)

        // Pinned, not incidental: a thread the reader is alone in must never reach the
        // Threads card, whatever a later change does to how the maximum is taken.
        #expect(try store.unreadThreads(selfPubkey: reader.pubkey).isEmpty)
    }

    /// The literal reading of the requirement — "the count needs to be based on whether the
    /// new message on the thread is not made by you" — pinned at the only layer that can
    /// enforce it for every device at once.
    ///
    /// Worth its own case because it is *not* what the read mark does. The mark is local and
    /// subtractive; this is the store refusing to hand the thread over in the first place, so
    /// the answer is the same on a phone that has never opened the thread as on one that has.
    @Test("a thread whose only reply past the frontier is the reader's own is not unread")
    func ownReplyPastTheFrontierIsNotUnread() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let opener = try peer.message("question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            // The reader is already part of the thread; this reply is behind the frontier
            // and must not change which peer reply is judged as new.
            try reply(reader, "already participated", to: opener, at: 1500),
            try reply(peer, "theirs", to: opener, at: 2000),
        ], phase: .backfill)
        #expect(try store.unreadThreads(selfPubkey: reader.pubkey).count == 1)

        // The channel is read to 2500, which settles the peer's reply — then the reader
        // answers at 3000, past the frontier. One reply is unread by the frontier's reckoning
        // and it is theirs, so the thread holds nothing new *to them*.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["room-1": 2500],
            sourceCreatedAt: 10, sourceEventID: "a"
        )
        _ = try await store.ingest(batch: [
            try reply(reader, "mine", to: opener, at: 3000),
        ], phase: .live)

        #expect(try store.unreadThreads(selfPubkey: reader.pubkey).isEmpty)
        let thread = try #require(
            try store.threadActivity(selfPubkey: reader.pubkey, limit: 10).first
        )
        #expect(thread.newReplyCount == 0)
        // Their own reply is the newest; the peer's is the newest anybody else wrote, and it
        // is behind the frontier — which is exactly the pair the Threads *screen* needs to
        // draw the thread without marking it new.
        #expect(thread.latestReply.createdAt == 3000)
        #expect(thread.latestReplyByOthersAt == 2000)
    }

    @Test("with no local identity every author counts, so both timestamps are the newest reply")
    func keylessFallbackCountsEveryAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let opener = try peer.message("question", in: "room-1", at: 1000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            opener,
            try reply(peer, "theirs", to: opener, at: 2000),
            try reply(reader, "would have been mine", to: opener, at: 3000),
        ], phase: .backfill)

        // Signed out, or signed in before the key is known: there is no "own" reply to
        // discount, so the two maxima are the same reply — the same keyless fallback the
        // unread count takes, and the reason the author filter is written as a `NULL` test
        // rather than as a `<>` against an empty string.
        let thread = try #require(try store.threadActivity(selfPubkey: nil, limit: 10).first)
        #expect(thread.newReplyCount == 2)
        #expect(thread.latestReplyByOthersAt == 3000)

        let unread = try #require(try store.unreadThreads(selfPubkey: nil).first)
        #expect(unread.latestReplyAt == 3000)
        #expect(unread.latestReplyByOthersAt == 3000)
    }
}
