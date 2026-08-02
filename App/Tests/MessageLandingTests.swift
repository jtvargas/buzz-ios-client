import BuzzKit
import Foundation
@testable import Hive
import Testing

@MainActor
@Suite("Message landing")
struct MessageLandingTests {
    @Test("a pending landing fires on the rebuild that first renders its row")
    func landsWhenPendingRowArrives() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let target = try author.message("target", in: "room-1", at: 1_000)
        let run = Task { await model.run() }
        defer { run.cancel() }

        model.pendingLanding = target.id
        _ = try await store.ingest(batch: [target], phase: .backfill)

        await waitUntil { model.pendingLanding == nil }
        #expect(model.jumpTarget == .message(target.id))
        #expect(model.jumpToken == 1)
    }

    @Test("a landing releases a frozen tail before jumping without changing isAtBottom")
    func landingReleasesFrozenTail() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let first = try author.message("first", in: "room-1", at: 1_000)
        let target = try author.message("target", in: "room-1", at: 1_001)
        _ = try await store.ingest(batch: [first], phase: .backfill)
        model.primeIfNeeded()

        model.isAtBottom = false
        model.pendingLanding = target.id
        _ = try await store.ingest(batch: [target], phase: .live)
        // Drive the same merge directly so this test isolates the frozen-tail/landing
        // contract from the separate observation-loop test above.
        _ = model.mergeHead(try store.timeline(channel: "room-1", before: nil, limit: 50))
        #expect(model.jump.unreadCount == 1)
        #expect(model.jumpTarget != .message(target.id))
        #expect(model.pendingLanding == target.id)

        let landed = model.prepareLanding(on: target.id)
        #expect(landed)
        #expect(model.isAtBottom == false)
        #expect(model.rows.contains(where: { $0.id == target.id }))
        #expect(model.jumpTarget == .message(target.id))
        #expect(model.pendingLanding == nil)
    }
}
