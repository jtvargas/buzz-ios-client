@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Cold-start delta sync (spec §Performance): a store whose watermark sits near the
/// head reconciles by fetching *only the offline gap*, not the whole channel. The
/// measurement pins both facts — the wall time to reach `synced`, and that a single
/// window page (not one per fifty events of history) is fetched — which is the
/// reliability delta over a fixed-window refetch. Env-gated (see ``Perf``).
@Suite("Cold-start delta sync", .enabled(if: Perf.enabled), .timeLimit(.minutes(5)))
struct ColdStartReconcileTests {
    @Test("A watermark near the head fetches one gap page, not the whole history")
    func deltaSyncFetchesOnlyTheGap() async throws {
        let historyCount = 3_000
        let gapFromHead = 40 // the watermark sits 40 events below the head

        let database = TempDatabase()
        let build = try WindowResponseBuilder(channel: "perf-coldstart-channel")

        // A large existing history, ascending by created_at (index 0 oldest).
        var history: [NostrEvent] = []
        history.reserveCapacity(historyCount)
        for index in 0 ..< historyCount {
            history.append(try build.row("m\(index)", at: 1_700_000_000 + Int64(index)))
        }
        let newest = history[historyCount - 1]
        let watermarkEvent = history[historyCount - 1 - gapFromHead]

        // Seed the store: the whole history is already on disk, and the durable
        // watermark records contiguity up to 40-below-head — the state a prior session
        // left behind.
        do {
            let store = try database.open()
            _ = try await store.ingest(batch: history, phase: .backfill)
            try await store.executeForTest("""
            INSERT INTO channel_sync (channel_id, watermark_created_at, watermark_id, head_synced)
            VALUES ('\(build.channel)', \(watermarkEvent.createdAt), '\(watermarkEvent.id)', 1)
            """)
        }
        // The store actor is released here; a fresh engine reopens the same file — a real
        // cold start, not a warm handle.

        let socket = ScriptedRelay()
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        defer { harness.remove() }

        // The head page: the newest 50 rows. Its oldest row is below the watermark, so
        // one page closes the gap — even though the relay advertises `has_more`.
        let headRows = Array(history.suffix(50).reversed()) // newest first
        let nextCursor = WindowCursor(
            createdAt: history[historyCount - 51].createdAt, id: history[historyCount - 51].id
        )
        let headBounds = try build.headBounds(hasMore: true, nextCursor: nextCursor)
        await harness.http.enqueue(status: 200, body: try WindowResponseBuilder.body(headRows + [headBounds]))

        let clock = ContinuousClock()
        let start = clock.now

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket) // channel is known from its watermark row

        await waitUntil { await harness.engine.channelSyncState(build.channel) == .synced }
        let seconds = Perf.seconds(since: start, on: clock)

        Perf.report("coldStart.deltaSync", String(format: """
        gap closed in %.2f ms — %d window request(s), %d rows fetched against a \
        %d-event channel
        """, seconds * 1000, await harness.http.requests.count, headRows.count, historyCount))

        // Only the gap was fetched: exactly one page, not one per fifty events of
        // history. The watermark advanced to the head; the store never re-grew (the
        // page's rows were all already present and deduped).
        #expect(await harness.http.requests.count == 1)
        #expect(try await harness.store.channelWatermark(build.channel)
            == WindowCursor(createdAt: newest.createdAt, id: newest.id))
        #expect(try await harness.store.count(kind: .channelMessage) == historyCount)

        // Loose guard: a single scripted round-trip, so this is orchestration overhead
        // only; a regression to whole-history paging would blow far past it.
        #expect(seconds < 30)

        await harness.engine.stop()
    }
}
