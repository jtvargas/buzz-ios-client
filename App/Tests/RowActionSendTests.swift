import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The timeline model's row actions route to the durable send path with the right
/// kind and tags — react (kind 7), withdraw (kind 5), and delete (discard).
@MainActor
@Suite("Row actions", .timeLimit(.minutes(1)))
struct RowActionSendTests {
    private func model(sender: RecordingSender, selfPubkey: String?) throws -> ChannelTimelineModel {
        let temp = TempStore()
        // The store is unused by these action paths, but the model needs one.
        return ChannelTimelineModel(
            channel: "room-1", store: try temp.open(), sender: sender, selfPubkey: selfPubkey
        )
    }

    @Test("react sends a kind-7 referencing the target, content the emoji")
    func reactSendsReaction() async throws {
        let sender = try RecordingSender()
        let model = try model(sender: sender, selfPubkey: nil)

        model.react("🎉", on: "TARGET")

        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.sent.first)
        #expect(sent.kind == .reaction)
        #expect(sent.content == "🎉")
        #expect(sent.tags == [["e", "TARGET"]])
    }

    @Test("toggling an own reaction withdraws it with a kind-5 naming the reaction")
    func toggleWithdrawsOwn() async throws {
        let sender = try RecordingSender()
        let model = try model(sender: sender, selfPubkey: "me")
        let own = ReactionGroup(emoji: "👍", count: 1, reactedBySelf: true, selfReactionID: "REACTION")

        model.toggleReaction(own, on: "TARGET")

        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.sent.first)
        #expect(sent.kind == .deletion)
        #expect(sent.content.isEmpty)
        #expect(sent.tags == [["e", "REACTION"]])
    }

    @Test("toggling an un-reacted chip adds that emoji instead")
    func toggleAddsWhenNotMine() async throws {
        let sender = try RecordingSender()
        let model = try model(sender: sender, selfPubkey: "me")
        let theirs = ReactionGroup(emoji: "🔥", count: 2, reactedBySelf: false, selfReactionID: nil)

        model.toggleReaction(theirs, on: "TARGET")

        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.sent.first)
        #expect(sent.kind == .reaction)
        #expect(sent.tags == [["e", "TARGET"]])
    }

    @Test("delete discards the row through the send path")
    func deleteDiscards() async throws {
        let sender = try RecordingSender()
        let model = try model(sender: sender, selfPubkey: "me")

        model.delete("EVENT")

        await waitUntil { await sender.discarded == ["EVENT"] }
    }
}
