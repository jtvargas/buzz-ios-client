@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The reply-preview read: the distinct people who replied in a thread, batched per
/// page, counting exactly the replies ``TimelineRow/replyCount`` counts.
@Suite("Thread participants read API", .timeLimit(.minutes(1)))
struct ThreadParticipantsTests {
    /// The number of faces the timeline row draws, and so the cap the app passes.
    private let previewLimit = 4

    /// A kind-9 reply threaded to `root` by NIP-10 marker.
    private func reply(
        _ author: Fixture,
        to root: NostrEvent,
        in channel: String = "room-1",
        broadcast: Bool = false,
        at seconds: Int64
    ) throws -> NostrEvent {
        var tags = [["h", channel], ["e", root.id, "", "reply"]]
        if broadcast { tags.append(["broadcast", "1"]) }
        return try author.event(.channelMessage, "reply", tags: tags, at: seconds)
    }

    @Test("returns each thread's distinct repliers in the order they first replied")
    func distinctRepliersInArrivalOrder() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        let root = try opener.message("root", at: 1000)
        _ = try await store.ingest(batch: [
            root,
            try reply(bob, to: root, at: 1001),
            try reply(alice, to: root, at: 1002),
        ], phase: .backfill)

        let participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        // Bob replied first, so Bob's face is leftmost — an order derived from the
        // newest reply would reshuffle the strip whenever anyone spoke again.
        #expect(Array(participants) == [bob.pubkey, alice.pubkey])
    }

    @Test("counts a repeat replier once, at the position they first replied")
    func repeatReplierCountsOnce() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        let root = try opener.message("root", at: 1000)
        _ = try await store.ingest(batch: [
            root,
            try reply(alice, to: root, at: 1001),
            try reply(bob, to: root, at: 1002),
            try reply(alice, to: root, at: 1003),
        ], phase: .backfill)

        let participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(participants) == [alice.pubkey, bob.pubkey])
    }

    @Test("the thread opener is a participant only once they reply in it")
    func openerCountsOnlyWhenTheyReply() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", at: 1000)
        _ = try await store.ingest(batch: [
            root,
            try reply(alice, to: root, at: 1001),
        ], phase: .backfill)

        var participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(participants) == [alice.pubkey])

        // The opener answers: now they are in the conversation they started.
        _ = try await store.ingest(batch: [
            try reply(opener, to: root, at: 1002),
        ], phase: .live)

        participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(participants) == [alice.pubkey, opener.pubkey])
    }

    @Test("keeps the earliest repliers when a thread has more than the limit")
    func capsAtTheLimit() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let repliers = try (0 ..< 6).map { _ in try Fixture() }

        let root = try opener.message("root", at: 1000)
        var batch = [root]
        for (index, replier) in repliers.enumerated() {
            batch.append(try reply(replier, to: root, at: 1001 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        let participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(participants) == repliers.prefix(previewLimit).map(\.pubkey))
    }

    @Test("breaks a same-second tie by pubkey, including at the limit that drops a face")
    func sameSecondTiesBreakByPubkey() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        // Five people whose replies all carry the *same* `created_at`. Nostr timestamps are
        // whole seconds, so this is not a contrivance: five clients answering a message in
        // the same second is one busy thread. With nothing but `first_at` to order by, which
        // face is leftmost — and, at the cap, which is dropped — would be SQLite's grouping
        // order, so the strip would reshuffle between two reads of an unchanged database.
        let repliers = try (0 ..< 5).map { _ in try Fixture() }
        let sorted = repliers.map(\.pubkey).sorted()

        let root = try opener.message("root", at: 1000)
        var batch = [root]
        for replier in repliers {
            batch.append(try reply(replier, to: root, at: 1001))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        // Asked for more than there are: the whole set, in pubkey order.
        let all = try #require(try store.threadParticipants(for: [root.id], limit: 10)[root.id])
        #expect(Array(all) == sorted)

        // And at the cap the *decision* the tie-break makes: the last pubkey is the one
        // dropped, deterministically, rather than whichever row the grouping happened to
        // hand back last.
        let capped = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(capped) == Array(sorted.prefix(previewLimit)))
        #expect(!capped.contains(sorted[previewLimit]))
    }

    @Test("drops a deleted reply's author, matching the reply tally's authority")
    func deletedReplyDropsItsAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        let root = try opener.message("root", at: 1000)
        let aliceReply = try reply(alice, to: root, at: 1001)
        _ = try await store.ingest(batch: [
            root,
            aliceReply,
            try reply(bob, to: root, at: 1002),
            // Alice withdraws her only reply, so she was never in this thread.
            try alice.event(.deletion, "", tags: [["e", aliceReply.id]], at: 1003),
        ], phase: .backfill)

        let row = try #require(try store.timeline(channel: "room-1").first { $0.id == root.id })
        let participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        // The faces and the number beside them come from the same authority.
        #expect(row.replyCount == 1)
        #expect(Array(participants) == [bob.pubkey])
    }

    @Test("counts a broadcast reply, which lives in the channel and its thread alike")
    func broadcastReplyCounts() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", at: 1000)
        _ = try await store.ingest(batch: [
            root,
            try reply(alice, to: root, broadcast: true, at: 1001),
        ], phase: .backfill)

        let participants = try #require(
            try store.threadParticipants(for: [root.id], limit: previewLimit)[root.id]
        )
        #expect(Array(participants) == [alice.pubkey])
    }

    @Test("keys each thread independently and omits a message with no replies")
    func perRootKeyingAndOmission() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let threaded = try opener.message("threaded", at: 1000)
        let quiet = try opener.message("quiet", at: 1001)
        _ = try await store.ingest(batch: [
            threaded,
            quiet,
            try reply(alice, to: threaded, at: 1002),
        ], phase: .backfill)

        let result = try store.threadParticipants(
            for: [threaded.id, quiet.id],
            limit: previewLimit
        )
        #expect(result[threaded.id].map(Array.init) == [alice.pubkey])
        // A message nobody replied to is simply absent — a missing key means "no thread".
        #expect(result[quiet.id] == nil)
    }

    @Test("returns nothing for an empty id list or a non-drawing limit")
    func degenerateInput() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let opener = try Fixture()
        let alice = try Fixture()

        let root = try opener.message("root", at: 1000)
        _ = try await store.ingest(batch: [
            root,
            try reply(alice, to: root, at: 1001),
        ], phase: .backfill)

        #expect(try store.threadParticipants(for: [], limit: previewLimit).isEmpty)
        #expect(try store.threadParticipants(for: [root.id], limit: 0).isEmpty)
    }
}
