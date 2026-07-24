@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Ingest throughput (spec §Performance): a large backfill batch through the store's
/// single verification-and-write choke point, reported as events/second. Env-gated —
/// see ``Perf`` for why a release-config timing measurement is gated rather than
/// smoke-ceilinged.
@Suite("Ingest throughput", .enabled(if: Perf.enabled), .timeLimit(.minutes(5)))
struct IngestThroughputTests {
    @Test("A 5,000-event backfill batch ingests through the choke point")
    func backfillThroughput() async throws {
        let count = 5_000
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        // Setup (not measured): sign the corpus across a handful of channels.
        let corpus = try PerfCorpus()
        let channels = (0 ..< 8).map { "perf-channel-\($0)" }
        let events = try await corpus.messages(count: count, channels: channels)

        // Measured: one batch, one parallel verify fan-out, one transaction.
        let (result, seconds) = try await Perf.measure {
            try await store.ingest(batch: events, phase: .backfill)
        }

        let perSecond = Double(count) / seconds
        Perf.report("ingest.throughput", String(
            format: "%d events in %.3fs = %.0f events/s", count, seconds, perSecond
        ))

        // Correctness: every event admitted and written exactly once, none rejected.
        #expect(result.inserted.count == count)
        #expect(result.rejected.isEmpty)
        #expect(try await store.count() == count)

        // A deliberately loose guard (≈ far under 5s expected): only trips on a
        // pathological regression, never on runner noise.
        #expect(seconds < 60)
    }
}
