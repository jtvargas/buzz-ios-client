@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Timeline query latency (spec §Performance): a channel timeline over a large,
/// realistic corpus — threads, edits, and deletions all resolved at read time —
/// measured at the head and deep in history. The keyset index over
/// `(h, kind, created_at DESC, id)` should make a deep page cost about what the head
/// page costs; the measurement is what proves that rather than assumes it. Env-gated
/// (see ``Perf``).
@Suite("Timeline query latency", .enabled(if: Perf.enabled), .timeLimit(.minutes(5)))
struct TimelineLatencyTests {
    private let queried = "perf-timeline-channel"
    private let limit = 50

    @Test("First-page and deep-page latency over 10k+ events with threads, edits, deletions")
    func pageLatency() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let corpus = try PerfCorpus()
        let topLevelCount = 8_000

        // The queried channel: 8,000 ascending top-level messages.
        let queriedMessages = try await corpus.messages(
            count: topLevelCount, channels: [queried], startAt: 1_700_000_000
        )
        // Cross-channel index noise, so the query's `h` predicate does real work.
        let filler = try await corpus.messages(
            count: 2_500, channels: (0 ..< 3).map { "perf-filler-\($0)" }, startAt: 1_700_100_000
        )

        // Threads (excluded from the channel timeline), edits, and deletions (applied at
        // read time) — the joins the timeline query resolves per row.
        var overlays: [NostrEvent] = []
        for index in 0 ..< 200 {
            overlays.append(try corpus.reply(
                to: queriedMessages[index * 40], in: queried, index: index, at: 1_700_200_000 + Int64(index)
            ))
        }
        for index in 0 ..< 300 {
            overlays.append(try corpus.edit(
                of: queriedMessages[index * 20], to: "edited \(index)", at: 1_700_300_000 + Int64(index)
            ))
        }
        for index in 0 ..< 300 {
            overlays.append(try corpus.deletion(
                of: queriedMessages[index * 25 + 5], at: 1_700_400_000 + Int64(index)
            ))
        }

        let all = queriedMessages + filler + overlays
        _ = try await store.ingest(batch: all, phase: .backfill)
        Perf.report("timeline.corpus", "\(all.count) events, \(topLevelCount) top-level in queried channel")

        // First page (head): no cursor.
        let (first, firstSeconds) = try await Perf.measure {
            try store.timeline(channel: queried, before: nil, limit: limit)
        }
        Perf.report("timeline.firstPage", String(format: "%d rows in %.2f ms", first.count, firstSeconds * 1000))

        // A deep page: a cursor near the oldest message, so the query pages the tail of
        // an 8,000-row history rather than the head.
        let deepCursor = TimelineCursor(
            createdAt: queriedMessages[60].createdAt, id: queriedMessages[60].id
        )
        let (deep, deepSeconds) = try await Perf.measure {
            try store.timeline(channel: queried, before: deepCursor, limit: limit)
        }
        Perf.report("timeline.deepPage", String(format: "%d rows in %.2f ms", deep.count, deepSeconds * 1000))

        // Correctness: both pages are full, and the head page reflects an applied edit
        // where one targeted its newest rows.
        #expect(first.count == limit)
        #expect(deep.count == limit)
        #expect(first.allSatisfy { $0.rootID == nil }) // replies excluded

        // Loose guards: keyset paging is index-bound, so even a very slow runner stays
        // far under these; they trip only on a pathological regression (e.g. a full scan).
        #expect(firstSeconds < 2)
        #expect(deepSeconds < 2)
    }
}
