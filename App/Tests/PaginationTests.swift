import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Timeline pagination", .timeLimit(.minutes(1)))
struct PaginationTests {
    @Test("older pages request the correct (createdAt, id) before-cursor, never an offset")
    func pagesByKeysetCursor() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        // 120 ascending messages, each at a distinct second so the keyset order is
        // unambiguous.
        var batch: [NostrEvent] = []
        for index in 0 ..< 120 {
            batch.append(try author.message("m\(index)", in: "room-1", at: 1_000 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender(), pageSize: 50)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // Head page: the newest 50, m70…m119 ascending.
        await waitUntil { model.rows.count == 50 }
        #expect(model.rows.first?.content == "m70")
        #expect(model.rows.last?.content == "m119")
        #expect(model.hasMoreOlder)

        // First older page: the cursor must be the oldest loaded row, m70.
        await model.loadOlder()
        #expect(model.lastOlderCursor == cursor(of: batch[70]))
        await waitUntil { model.rows.count == 100 }
        #expect(model.rows.first?.content == "m20")
        #expect(model.hasMoreOlder)

        // Second older page: cursor m20 → returns m0…m19 (20 rows) and exhausts.
        await model.loadOlder()
        #expect(model.lastOlderCursor == cursor(of: batch[20]))
        await waitUntil { model.rows.count == 120 }
        #expect(model.rows.first?.content == "m0")
        #expect(!model.hasMoreOlder)

        // A load past exhaustion is a no-op and does not re-page.
        await model.loadOlder()
        #expect(model.lastOlderCursor == cursor(of: batch[20]))
        #expect(model.rows.count == 120)
    }

    @Test("a frozen tail changes nothing about where pagination resumes")
    func freezeDoesNotDisturbPagination() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()

        // 25 messages at pageSize 10: pages of 10, 10, then a short 5 that exhausts.
        var batch: [NostrEvent] = []
        for index in 0 ..< 25 {
            batch.append(try author.message("m\(index)", in: "room-1", at: 1_000 + Int64(index)))
        }
        _ = try await store.ingest(batch: batch, phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 10
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.count == 10 }
        #expect(model.rows.first?.content == "m15")

        // The reader scrolls up into history: the tail freezes at m24, and a message
        // arriving now is held back.
        model.isAtBottom = false
        _ = try await store.ingest(batch: [
            try author.message("arrival", in: "room-1", at: 2_000),
        ], phase: .live)
        await waitUntil { model.jump.unreadCount == 1 }

        // Older pages still page from the oldest *loaded* row, which the freeze never
        // touches — the freeze is a tail, and `earliest` is a head. Both pages land,
        // and the held-back arrival stays held.
        await model.loadOlder()
        #expect(model.lastOlderCursor == cursor(of: batch[15]))
        #expect(model.rows.first?.content == "m5")
        #expect(model.rows.count == 20)
        #expect(model.jump.unreadCount == 1)

        await model.loadOlder()
        #expect(model.lastOlderCursor == cursor(of: batch[5]))
        #expect(model.rows.first?.content == "m0")
        #expect(model.rows.count == 25)
        #expect(model.jump.unreadCount == 1)
        #expect(!model.hasMoreOlder)

        // And releasing it renders the arrival on the end of the full history.
        model.jumpToLatest()
        #expect(model.rows.count == 26)
        #expect(model.rows.last?.content == "arrival")
    }

    private func cursor(of event: NostrEvent) -> TimelineCursor {
        TimelineCursor(createdAt: event.createdAt, id: event.id)
    }
}
