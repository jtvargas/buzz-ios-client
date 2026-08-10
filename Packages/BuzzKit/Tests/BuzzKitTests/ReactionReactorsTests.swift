@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Who reacted, rather than how many: the read behind the sheet a held chip opens.
///
/// The invariant these are really about is that this read and ``ReactionsTests``' cannot
/// disagree — a chip saying 2 and a list naming three people would be two tallies, and
/// there is deliberately only one. Several of these assert both reads in the same breath
/// for that reason.
@Suite("Reaction reactors read API", .timeLimit(.minutes(1)))
struct ReactionReactorsTests {
    // MARK: - Grouping and order

    @Test("groups reactors by emoji, in the same order the chips are drawn")
    func groupsInChipOrder() async throws {
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

        let groups = try store.reactors(for: target.id, selfPubkey: me.pubkey)
        // 👍 (first at 1001) before ❤️ (1003) — the chips' own ordering.
        #expect(groups.map(\.emoji) == ["👍", "❤️"])
        // And within an emoji, oldest reaction first.
        #expect(groups[0].reactors == [me.pubkey, peer.pubkey])
        #expect(groups[1].reactors == [peer.pubkey])
    }

    @Test("every group's reactor count is the count the chip shows")
    func countsMatchTheChips() async throws {
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
            try peer.event(.reaction, "🎉", tags: [["e", target.id]], at: 1003),
        ], phase: .backfill)

        let chips = try #require(try store.reactions(for: [target.id], selfPubkey: me.pubkey)[target.id])
        let lists = try store.reactors(for: target.id, selfPubkey: me.pubkey)

        #expect(chips.map(\.emoji) == lists.map(\.emoji))
        #expect(chips.map(\.count) == lists.map(\.count))
    }

    @Test("a member who reacted twice with one emoji is named once")
    func namesDistinctReactors() async throws {
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

        let group = try #require(try store.reactors(for: target.id, selfPubkey: nil).first)
        #expect(group.reactors == [peer.pubkey])
    }

    @Test("a message nobody reacted to has no groups at all")
    func noReactions() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)

        _ = try await store.ingest(batch: [target], phase: .backfill)

        #expect(try store.reactors(for: target.id, selfPubkey: nil).isEmpty)
    }

    // MARK: - Withdrawal (the same read-time authority the chips apply)

    @Test("a withdrawn reaction takes its reactor out of the list")
    func withdrawnReactorDrops() async throws {
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
        #expect(try store.reactors(for: target.id, selfPubkey: me.pubkey).first?.count == 2)

        _ = try await store.ingest(
            batch: [try me.event(.deletion, "", tags: [["e", mine.id]], at: 1003)],
            phase: .backfill
        )

        let group = try #require(try store.reactors(for: target.id, selfPubkey: me.pubkey).first)
        #expect(group.reactors == [peer.pubkey])
    }

    @Test("an emoji whose last reactor withdrew disappears rather than listing nobody")
    func emptiedEmojiDisappears() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let me = try Fixture()
        let target = try author.message("hi", at: 1000)
        let mine = try me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)

        _ = try await store.ingest(batch: [
            target,
            mine,
            try me.event(.deletion, "", tags: [["e", mine.id]], at: 1002),
        ], phase: .backfill)

        #expect(try store.reactors(for: target.id, selfPubkey: me.pubkey).isEmpty)
    }

    // MARK: - Optimistic own reactions

    /// One store, one identity, and its signer — the same shape
    /// ``OptimisticReactionsTests`` uses, because the layer under test is the same one.
    private struct Harness {
        let store: BuzzEventStore
        let database: TempDatabase
        let me: Fixture
        let signer: InMemorySigner

        init() throws {
            database = TempDatabase()
            store = try database.open()
            me = try Fixture()
            signer = InMemorySigner(me.key)
        }

        func remove() { database.remove() }

        @discardableResult
        func react(_ emoji: String, on target: String, at seconds: Int64 = 2000) async throws -> String {
            try await store.enqueue(
                kind: .reaction, content: emoji, in: "room-1", tags: [["e", target]],
                with: signer, createdAt: Date(timeIntervalSince1970: TimeInterval(seconds))
            ).event.id
        }

        @discardableResult
        func withdraw(reactionID: String, at seconds: Int64 = 2001) async throws -> String {
            try await store.enqueue(
                kind: .deletion, content: "", in: "room-1", tags: [["e", reactionID]],
                with: signer, createdAt: Date(timeIntervalSince1970: TimeInterval(seconds))
            ).event.id
        }
    }

    @Test("a queued own reaction names the reader before the relay confirms it")
    func pendingReactionNamesSelf() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [
            target,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1001),
        ], phase: .backfill)

        _ = try await harness.react("👍", on: target.id)

        let group = try #require(
            try harness.store.reactors(for: target.id, selfPubkey: harness.me.pubkey).first
        )
        // Appended, because a reaction just sent is the newest one.
        #expect(group.reactors == [peer.pubkey, harness.me.pubkey])
    }

    @Test("a queued reaction with a brand-new emoji adds that page at the end")
    func pendingReactionAddsNewEmoji() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [
            target,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1001),
        ], phase: .backfill)

        _ = try await harness.react("🎉", on: target.id)

        let groups = try harness.store.reactors(for: target.id, selfPubkey: harness.me.pubkey)
        #expect(groups.map(\.emoji) == ["👍", "🎉"])
        #expect(groups[1].reactors == [harness.me.pubkey])
    }

    @Test("a queued withdrawal takes the reader out of the list at once")
    func pendingWithdrawalRemovesSelf() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)
        let mine = try harness.me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)
        _ = try await harness.store.ingest(batch: [
            target,
            mine,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1002),
        ], phase: .backfill)

        _ = try await harness.withdraw(reactionID: mine.id)

        let group = try #require(
            try harness.store.reactors(for: target.id, selfPubkey: harness.me.pubkey).first
        )
        #expect(group.reactors == [peer.pubkey])
    }

    @Test("no identity means no optimistic layer, and the confirmed list still reads")
    func keylessDegradation() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let peer = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [
            target,
            try peer.event(.reaction, "👍", tags: [["e", target.id]], at: 1001),
        ], phase: .backfill)

        _ = try await harness.react("👍", on: target.id)

        // The same keyless degradation the highlight takes: the queued own reaction is
        // invisible without an identity to attribute it to, and the peer still reads.
        let group = try #require(try harness.store.reactors(for: target.id, selfPubkey: nil).first)
        #expect(group.reactors == [peer.pubkey])
    }
}
