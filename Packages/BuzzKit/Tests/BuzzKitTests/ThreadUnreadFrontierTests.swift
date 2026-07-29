@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The frontier comparison behind ``unreadThreads(selfPubkey:)``, in its own suite.
///
/// Split from ``ThreadActivityTests`` rather than added to it: that suite is about what the
/// Threads screen shows, and these two are about the one predicate the sidebar's per-commit
/// read is built on — written twice since the read became two passes, and therefore able to
/// disagree with itself.
@Suite("Unread thread frontier", .timeLimit(.minutes(1)))
struct ThreadUnreadFrontierTests {
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

    /// The narrowest reply that still counts as new.
    ///
    /// ``unreadThreads(selfPubkey:)`` now decides which threads can qualify in a first pass
    /// and aggregates only those (see ``threadCandidateCTE``), so the frontier comparison is
    /// written twice and both copies have to agree. `newRepliesFollowTheFrontier` pins the
    /// closed end — a reply *at* the frontier is read — and nothing pinned the open one, so
    /// a bound shifted by a single second in either copy dropped a thread silently. It is
    /// the only mutant of that pass this suite could not see.
    @Test("a reply one second past the frontier is still new")
    func aReplyJustPastTheFrontierIsNew() async throws {
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
            try reply(peer, "read", to: opener, at: 2000),
        ], phase: .backfill)
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: ["room-1": 2000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )
        #expect(try store.unreadThreads(selfPubkey: selfPubkey).isEmpty)

        _ = try await store.ingest(
            batch: [try reply(peer, "one second later", to: opener, at: 2001)], phase: .live
        )
        let unread = try #require(try store.unreadThreads(selfPubkey: selfPubkey).first)
        #expect(unread.rootID == opener.id)
        #expect(unread.newReplyCount == 1)
    }

    /// A reply is judged against the frontier of the channel its **root** lives in, not the
    /// one it claims for itself.
    ///
    /// `thread.channel_id` is the reply's own `h`, and a relay that does not enforce the two
    /// agreeing can hand over a reply naming another channel — so the query joins the
    /// frontier through `root.h` and a comment says so. Nothing checked it. Pointed at a
    /// channel read further than its own, reading the wrong one does not merely mis-scope
    /// the thread, it hides it.
    @Test("a reply is judged by its root's channel, not the one it names")
    func frontierComesFromTheRootsChannel() async throws {
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
            try meta(relay, "room-2", name: "Two"),
            opener,
            // Replies to a room-1 thread while naming room-2 as its own group.
            try reply(peer, "mis-scoped", to: opener, in: "room-2", at: 2000),
        ], phase: .backfill)

        // room-1 read to before the reply, room-2 read to well past it.
        try await store.applyReadState(
            author: selfPubkey, slot: "phone",
            contexts: ["room-1": 1500, "room-2": 9000],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        let unread = try #require(try store.unreadThreads(selfPubkey: selfPubkey).first)
        #expect(unread.rootID == opener.id, "room-2's frontier must not reach a room-1 thread")
        #expect(unread.newReplyCount == 1)
    }
}
