@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The S-2 reactions read API: aggregation over the `reaction` projection, the
/// own-reaction state a chip highlights, and the read-time withdrawal authority
/// that mirrors the timeline's deletion predicate.
@Suite("Reactions read API", .timeLimit(.minutes(1)))
struct ReactionsTests {
    // MARK: - Aggregation

    @Test("groups reactions by emoji, counting distinct reactors")
    func aggregatesByEmoji() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)

        _ = try await store.ingest(batch: [
            target,
            try me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001),
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1002),
            try peer.event(.reaction, "❤️", tags: [["e", target.id]], at: 1003),
        ], phase: .backfill)

        let groups = try #require(
            try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id]
        )
        // Ordered oldest-emoji first: 👍 (first at 1001) before ❤️ (1003).
        #expect(groups.map(\.emoji) == ["👍", "❤️"])
        #expect(groups[0].count == 2)
        #expect(groups[1].count == 1)
    }

    @Test("counts a reactor once even across duplicate same-emoji reactions")
    func countsDistinctReactors() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)

        _ = try await store.ingest(batch: [
            target,
            try peer.event(.reaction, "🎉", tags: [["e", target.id]], at: 1001),
            try peer.event(.reaction, "🎉", tags: [["e", target.id]], at: 1002),
        ], phase: .backfill)

        let groups = try #require(try store.reactions(for: [target.id], selfPubkey: nil)[target.id])
        #expect(groups.count == 1)
        #expect(groups[0].count == 1)
    }

    @Test("normalises a bare like to a heart, matching the projector")
    func normalisesLike() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)

        _ = try await store.ingest(batch: [
            target,
            try peer.event(.reaction, "", tags: [["e", target.id]], at: 1001),
        ], phase: .backfill)

        let groups = try #require(try store.reactions(for: [target.id], selfPubkey: nil)[target.id])
        #expect(groups.map(\.emoji) == ["❤️"])
    }

    // MARK: - Own-reaction state

    @Test("marks the local identity's own reaction and carries its id for withdrawal")
    func ownReactionState() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)
        let mine = try me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)

        _ = try await store.ingest(batch: [
            target,
            mine,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1002),
        ], phase: .backfill)

        let group = try #require(
            try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id]?.first
        )
        #expect(group.reactedBySelf)
        #expect(group.selfReactionID == mine.id)
    }

    @Test("does not mark self when only a peer reacted, and carries no withdrawal id")
    func notReactedBySelf() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)

        _ = try await store.ingest(batch: [
            target,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1001),
        ], phase: .backfill)

        let group = try #require(
            try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id]?.first
        )
        #expect(!group.reactedBySelf)
        #expect(group.selfReactionID == nil)
    }

    // MARK: - Withdrawal (read-time authority)

    @Test("a kind-5 by the reaction's author withdraws it: count drops, highlight clears")
    func withdrawByAuthor() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let target = try author.message("hi", at: 1000)
        let mine = try me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)

        _ = try await store.ingest(batch: [target, mine], phase: .backfill)
        // Present before the withdrawal.
        let before = try #require(
            try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id]?.first
        )
        #expect(before.count == 1)
        #expect(before.reactedBySelf)

        // The reaction's author withdraws it (kind-5 naming the reaction).
        _ = try await store.ingest(
            batch: [try me.event(.deletion, "", tags: [["e", mine.id]], at: 1002)],
            phase: .backfill
        )

        // The whole group is gone — no surviving reactions for the target.
        #expect(try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id] == nil)
    }

    @Test("a kind-5 from someone other than the reaction author does not withdraw it")
    func withdrawalRequiresAuthority() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let intruder = try Fixture()
        let target = try author.message("hi", at: 1000)
        let mine = try me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)

        _ = try await store.ingest(batch: [
            target,
            mine,
            // Not the reaction's author, not its owner: no authority to withdraw.
            try intruder.event(.deletion, "", tags: [["e", mine.id]], at: 1002),
        ], phase: .backfill)

        let group = try #require(
            try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id]?.first
        )
        #expect(group.count == 1)
        #expect(group.reactedBySelf)
    }

    // MARK: - Shape

    @Test("returns nothing for an empty target list or a target with no reactions")
    func emptyCases() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await store.ingest(batch: [target], phase: .backfill)

        #expect(try store.reactions(for: [], selfPubkey: nil).isEmpty)
        #expect(try store.reactions(for: [target.id], selfPubkey: nil).isEmpty)
    }
}
