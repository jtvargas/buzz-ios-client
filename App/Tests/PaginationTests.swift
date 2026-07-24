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

    private func cursor(of event: NostrEvent) -> TimelineCursor {
        TimelineCursor(createdAt: event.createdAt, id: event.id)
    }
}
