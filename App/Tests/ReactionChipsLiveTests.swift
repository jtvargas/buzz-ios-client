import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Reaction chips, live", .timeLimit(.minutes(1)))
struct ReactionChipsLiveTests {
    @Test("react raises a highlighted chip; withdraw drops it — live through the observation")
    func reactAndWithdrawLive() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let me = try Fixture()
        let author = try Fixture()
        let root = try author.message("hello", in: "room-1", at: 1_000)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), selfPubkey: me.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [root], phase: .backfill)
        await waitUntil { model.rows.count == 1 }
        #expect(model.reactions(for: root.id).isEmpty)

        // My reaction lands (as when the relay echoes it into the log): the chip
        // appears, counted and highlighted, carrying my reaction id for withdrawal.
        let mine = try me.event(.reaction, "👍", tags: [["e", root.id]], at: 1_001)
        _ = try await store.ingest(batch: [mine], phase: .backfill)

        await waitUntil { model.reactions(for: root.id).first?.reactedBySelf == true }
        let group = try #require(model.reactions(for: root.id).first)
        #expect(group.emoji == "👍")
        #expect(group.count == 1)
        #expect(group.selfReactionID == mine.id)

        // Withdraw it (my kind-5 naming the reaction): count drops, highlight clears.
        let withdraw = try me.event(.deletion, "", tags: [["e", mine.id]], at: 1_002)
        _ = try await store.ingest(batch: [withdraw], phase: .backfill)

        await waitUntil { model.reactions(for: root.id).isEmpty }
    }

    @Test("a peer's reaction shows a chip that is not highlighted as mine")
    func peerReactionNotMine() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let me = try Fixture()
        let peer = try Fixture()
        let root = try me.message("hello", in: "room-1", at: 1_000)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), selfPubkey: me.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            root,
            try peer.event(.reaction, "🎉", tags: [["e", root.id]], at: 1_001),
        ], phase: .backfill)

        await waitUntil { model.reactions(for: root.id).first?.emoji == "🎉" }
        let group = try #require(model.reactions(for: root.id).first)
        #expect(group.count == 1)
        #expect(!group.reactedBySelf)
        #expect(group.selfReactionID == nil)
    }
}
