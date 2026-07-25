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

    @Test("mark-on-view marks the channel read up to the newest message, once per advance")
    func marksOnView() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let marker = RecordingReadStateMarker()

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), readStateMarking: marker
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("one", in: "room-1", at: 1_000),
            try author.message("two", in: "room-1", at: 2_000),
        ], phase: .backfill)

        // Opening the channel marks it read up to the newest message, exactly once.
        await waitUntil { model.rows.count == 2 }
        await waitUntil { await marker.lastUpTo == 2_000 }
        #expect(await marker.upTos == [2_000])

        // A newer arrival re-marks; a re-read that adds nothing newer (here, the same
        // rows re-observed) never does, so the frontier only ever advances.
        _ = try await store.ingest(batch: [
            try author.message("three", in: "room-1", at: 3_000),
        ], phase: .live)
        await waitUntil { model.rows.count == 3 }
        await waitUntil { await marker.lastUpTo == 3_000 }
        #expect(await marker.upTos == [2_000, 3_000])
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
