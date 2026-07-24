import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Channel-timeline model", .timeLimit(.minutes(1)))
struct ChannelTimelineModelTests {
    @Test("streams an ingested batch into rows, oldest-first, without manual refresh")
    func streamsBatch() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
            try author.message("two", in: "room-1", at: 1_001),
            try author.message("three", in: "room-1", at: 1_002),
        ], phase: .backfill)

        await waitUntil { model.rows.count == 3 }
        // Ascending, so the bottom-anchored view renders newest last.
        #expect(model.rows.map(\.content) == ["one", "two", "three"])
        #expect(model.rows.allSatisfy { $0.delivery == .sent })
    }

    @Test("a message in another channel does not appear")
    func scopedToChannel() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("here", in: "room-1", at: 1_000),
            try author.message("elsewhere", in: "room-2", at: 1_001),
        ], phase: .backfill)

        await waitUntil { model.rows.count == 1 }
        #expect(model.rows.map(\.content) == ["here"])
    }
}
