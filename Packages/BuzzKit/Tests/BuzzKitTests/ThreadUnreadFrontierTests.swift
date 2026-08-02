@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// How ``unreadThreads(selfPubkey:)``'s two passes decide, in their own suite.
///
/// Split from ``ThreadActivityTests`` rather than added to it: that suite is about what the
/// Threads screen shows, and these are about the two predicates the sidebar's per-commit
/// read turns on. The frontier comparison is written twice, once per pass, and is therefore
/// able to disagree with itself. The deletion check is written once, in the second pass
/// only, and the first pass is deliberately built to get it wrong.
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

    /// The case the first pass is *designed* to get wrong.
    ///
    /// ``threadCandidateCTE`` omits the deletion check on purpose — that omission is what
    /// makes it a superset, and the superset is what makes the split safe — so it admits a
    /// root on the strength of a reply the second pass then discards. Two things downstream
    /// have to hold for that to be harmless: the reply CTE still applies the deletion check,
    /// and `HAVING new_count > 0` still drops a root left with nothing new. Nothing in the
    /// suite exercised the pair. ``ThreadActivityTests`` deletes an *opener*, which the
    /// aggregate rejects on its own root join and which never reaches this interaction, and
    /// its one deleted-reply test calls `threadActivity()`, which does not run the candidate
    /// pass at all.
    ///
    /// The thread is given a second, already-read reply so it still groups after the
    /// deletion: with `new_count` at zero and a row to carry it, `HAVING` is what strikes it
    /// off rather than the group vanishing. And the live thread beside it is what makes the
    /// absence mean something — `unreadThreads()` returning nothing is the answer to a great
    /// many broken states, while returning exactly the live root is the answer to this one.
    @Test("a candidate whose only new reply is deleted does not survive the aggregate")
    func aDeletedNewReplyStrikesOffItsCandidate() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()
        let selfPubkey = reader.pubkey

        let doomed = try reader.message("answered twice", in: "room-1", at: 1000)
        let live = try reader.message("answered once", in: "room-1", at: 1100)
        let doomedReply = try reply(peer, "about to go", to: doomed, at: 2000)
        _ = try await store.ingest(batch: [
            try meta(relay, "room-1", name: "One"),
            doomed, live,
            // Behind the frontier, and it survives — so `doomed` still has a reply, and so
            // still groups, once the new one is deleted.
            try reply(peer, "read long ago", to: doomed, at: 1200),
            doomedReply,
            try reply(peer, "still here", to: live, at: 2100),
        ], phase: .backfill)
        try await store.applyReadState(
            author: selfPubkey, slot: "phone", contexts: ["room-1": 1500],
            sourceCreatedAt: 10, sourceEventID: "a"
        )

        // Both roots qualify first, so the deletion is the only thing that differs below.
        // Without this the assertion after it would pass just as well for a thread the
        // candidate pass had never admitted.
        var unread = try store.unreadThreads(selfPubkey: selfPubkey)
        #expect(unread.map(\.rootID) == [live.id, doomed.id])
        #expect(unread.map(\.newReplyCount) == [1, 1])

        _ = try await store.ingest(batch: [
            try peer.event(.deletion, "", tags: [["e", doomedReply.id]], at: 2001),
        ], phase: .live)

        unread = try store.unreadThreads(selfPubkey: selfPubkey)
        #expect(unread.map(\.rootID) == [live.id], "a deleted reply cannot be a new one")
        #expect(unread.map(\.newReplyCount) == [1])
        // `doomed` is still a thread and still holds a surviving reply: it was struck off
        // for having nothing new, not because the row went missing under it.
        let activity = try store.threadActivity(selfPubkey: selfPubkey, limit: 10)
        #expect(activity.map(\.rootID) == [live.id, doomed.id])
        #expect(activity.map(\.newReplyCount) == [1, 0])
    }
}
