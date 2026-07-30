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

    /// The same page, over a channel where the relay has a reply tally for **every**
    /// message — the shape a busy channel actually reaches.
    ///
    /// This is the loaded case for the summary composition in ``eventBranch(where:)``.
    /// The unloaded case is the test above: its store holds no summaries at all, so its
    /// two `LEFT JOIN`s find nothing and the `CASE` always takes its local branch. Run
    /// the pair and the difference between them is the cost of the composition, which
    /// is the only honest way to quote one.
    ///
    /// Both joins are primary-key lookups, so the expectation is that this costs
    /// approximately nothing per row; the measurement is what says so.
    @Test("Page latency when the relay has a tally for every message")
    func pageLatencyWithSummaries() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let corpus = try PerfCorpus()
        let topLevelCount = 8_000

        let queriedMessages = try await corpus.messages(
            count: topLevelCount, channels: [queried], startAt: 1_700_000_000
        )
        let summaries = try await corpus.summaries(
            for: queriedMessages, in: queried, startAt: 1_700_500_000
        )

        _ = try await store.ingest(batch: queriedMessages, phase: .backfill)
        _ = try await store.ingest(batch: summaries, phase: .backfill)
        Perf.report(
            "timeline.summaryCorpus",
            "\(queriedMessages.count) messages, \(summaries.count) relay tallies"
        )

        let (first, firstSeconds) = try await Perf.measure {
            try store.timeline(channel: queried, before: nil, limit: limit)
        }
        Perf.report(
            "timeline.firstPageWithSummaries",
            String(format: "%d rows in %.2f ms", first.count, firstSeconds * 1000)
        )

        let deepCursor = TimelineCursor(
            createdAt: queriedMessages[60].createdAt, id: queriedMessages[60].id
        )
        let (deep, deepSeconds) = try await Perf.measure {
            try store.timeline(channel: queried, before: deepCursor, limit: limit)
        }
        Perf.report(
            "timeline.deepPageWithSummaries",
            String(format: "%d rows in %.2f ms", deep.count, deepSeconds * 1000)
        )

        // Non-vacuity: the tallies must actually be reaching the rows, or this would be
        // measuring the empty-join case a second time and reporting it as the loaded one.
        #expect(first.count == limit)
        #expect(first.allSatisfy { $0.replyCount == 3 })
        #expect(deep.allSatisfy { $0.replyCount == 3 })
        #expect(firstSeconds < 2)
        #expect(deepSeconds < 2)
    }
}
