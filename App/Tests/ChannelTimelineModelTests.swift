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

    @Test("page one is on screen before any observation fires, with its reactions")
    func primesFirstPageInInit() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let first = try author.message("one", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [
            first,
            try author.message("two", in: "room-1", at: 1_001),
            try author.event(.reaction, "👍", tags: [["e", first.id]], at: 1_002),
        ], phase: .backfill)

        // No `run()`: nothing has observed anything. Everything below is what the
        // first layout of the scroll view sees, which is the whole point — a bottom
        // anchor resolved against an empty stack is the "opens in the wrong place and
        // then jumps" defect.
        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())

        #expect(model.hasLoaded)
        #expect(model.rows.map(\.content) == ["one", "two"])
        // A short channel knows it is short at init, so no top spinner is reserved and
        // no first-frame `loadOlder()` fires into an empty cursor.
        #expect(!model.hasMoreOlder)
        // Grouped, so the day separator is part of that same first layout.
        #expect(shape(model.items) == ["day", "one", "two"])
        // And chips too: a reaction row appearing a frame later is another content
        // height change at the bottom.
        #expect(model.reactions(for: first.id).first?.emoji == "👍")
    }

    @Test("a full first page leaves pagination open at init")
    func fullFirstPageOffersOlder() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        var batch: [NostrEvent] = []
        for index in 0 ..< 12 {
            batch.append(try author.message("m\(index)", in: "room-1", at: 1_000 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 10
        )
        #expect(model.rows.count == 10)
        #expect(model.hasMoreOlder)
    }

    @Test("grouped items are recomputed when rows change, one separator per local day")
    func regroupsOnRowsChange() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        // Two days apart, so the boundary holds in any device time zone.
        let twoDays: Int64 = 2 * 86_400
        _ = try await store.ingest(batch: [
            try author.message("monday", in: "room-1", at: 1_000),
        ], phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        #expect(shape(model.items) == ["day", "monday"])

        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try author.message("wednesday", in: "room-1", at: 1_000 + twoDays),
        ], phase: .live)

        await waitUntil { model.rows.count == 2 }
        #expect(shape(model.items) == ["day", "monday", "day", "wednesday"])
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
