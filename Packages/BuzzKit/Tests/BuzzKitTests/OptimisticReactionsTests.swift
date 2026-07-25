@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The optimistic own-reaction layer: a queued reaction (or withdrawal) shows in the
/// reaction read the instant it is enqueued, before the relay round trip, and is not
/// double-counted once its own copy lands in the log. This is the fix for the relay's
/// pre-fanout reaction dedup — an own re-react produces no live kind-7 echo, so the UI
/// must read the outbox rather than wait for one.
@Suite("Optimistic own reactions", .timeLimit(.minutes(1)))
struct OptimisticReactionsTests {
    /// One store, one identity, and its signer — everything an enqueue needs.
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

        /// Enqueues an own reaction and returns the queued event id.
        @discardableResult
        func react(_ emoji: String, on target: String, at seconds: Int64 = 2000) async throws -> String {
            try await store.enqueue(
                kind: .reaction, content: emoji, in: "room-1", tags: [["e", target]],
                with: signer, createdAt: Date(timeIntervalSince1970: TimeInterval(seconds))
            ).event.id
        }

        /// Enqueues an own withdrawal naming a reaction, returning the queued event id.
        @discardableResult
        func withdraw(reactionID: String, at seconds: Int64 = 2001) async throws -> String {
            try await store.enqueue(
                kind: .deletion, content: "", in: "room-1", tags: [["e", reactionID]],
                with: signer, createdAt: Date(timeIntervalSince1970: TimeInterval(seconds))
            ).event.id
        }

        func groups(for target: String) throws -> [ReactionGroup] {
            try store.reactions(for: [target], selfPubkey: me.pubkey)[target] ?? []
        }
    }

    @Test("a queued own reaction shows a highlighted chip before the relay confirms it")
    func pendingReactionShowsOptimistically() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [target], phase: .backfill)

        let reactionID = try await harness.react("👍", on: target.id)

        let group = try #require(try harness.groups(for: target.id).first)
        #expect(group.emoji == "👍")
        #expect(group.count == 1)
        #expect(group.reactedBySelf)
        // The chip carries the queued reaction's id, so a tap can withdraw it even
        // before it is acknowledged.
        #expect(group.selfReactionID == reactionID)
    }

    @Test("a queued own reaction adds the identity to a peer's existing chip")
    func pendingReactionIncrementsPeerGroup() async throws {
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

        let group = try #require(try harness.groups(for: target.id).first)
        #expect(group.count == 2)
        #expect(group.reactedBySelf)
    }

    @Test("confirming a queued reaction does not double-count it")
    func confirmedReactionCountedOnce() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [target], phase: .backfill)

        let entry = try await harness.store.enqueue(
            kind: .reaction, content: "🎉", in: "room-1", tags: [["e", target.id]],
            with: harness.signer, createdAt: Date(timeIntervalSince1970: 2000)
        )
        // Optimistic: one, from the outbox.
        #expect(try harness.groups(for: target.id).first?.count == 1)

        // The relay accepts it; the row moves into the log. The optimistic layer drops
        // it (its own copy now exists), and the projection counts the one confirmed
        // reaction — never both.
        try await harness.store.confirmSent(entry.event)

        let group = try #require(try harness.groups(for: target.id).first)
        #expect(group.count == 1)
        #expect(group.reactedBySelf)
        #expect(group.selfReactionID == entry.event.id)
    }

    @Test("a queued withdrawal clears a confirmed own chip optimistically")
    func pendingWithdrawalHidesOwnChip() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        // My reaction is already in the log (the relay echoed it back).
        let mine = try harness.me.event(.reaction, "👍", tags: [["e", target.id]], at: 1001)
        _ = try await harness.store.ingest(batch: [target, mine], phase: .backfill)
        #expect(try harness.groups(for: target.id).first?.reactedBySelf == true)

        // Tapping the chip queues a withdrawal; the chip clears before it confirms.
        _ = try await harness.withdraw(reactionID: mine.id)

        #expect(try harness.groups(for: target.id).isEmpty)
    }

    @Test("a queued reaction and its queued withdrawal net to no chip")
    func pendingReactAndWithdrawNetToNothing() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [target], phase: .backfill)

        let reactionID = try await harness.react("👍", on: target.id, at: 2000)
        _ = try await harness.withdraw(reactionID: reactionID, at: 2001)

        #expect(try harness.groups(for: target.id).isEmpty)
    }

    @Test("no local identity means no optimistic layer")
    func keylessDegradation() async throws {
        let harness = try Harness()
        defer { harness.remove() }
        let author = try Fixture()
        let target = try author.message("hi", at: 1000)
        _ = try await harness.store.ingest(batch: [target], phase: .backfill)
        _ = try await harness.react("👍", on: target.id)

        // A keyless read cannot know the reaction is the local identity's own, so the
        // queued row is not folded in — the same posture the highlight takes.
        #expect(try harness.store.reactions(for: [target.id], selfPubkey: nil)[target.id] == nil)
    }
}
