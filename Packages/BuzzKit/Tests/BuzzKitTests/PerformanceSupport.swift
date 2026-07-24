@testable import BuzzKit
import Foundation
import NostrCore

/// Shared plumbing for the performance-measurement suites.
///
/// # Why the measurements are env-gated, not smoke-ceilinged
///
/// The spec offers two ways to keep a timing test from ever flaking CI: assert only a
/// generous ceiling (e.g. 10× expected), or gate the whole measurement behind an env
/// var alongside the live suite. These suites take the **env-gate** approach, for two
/// reasons the ceiling approach cannot satisfy at once:
///
/// 1. `make test` runs release, and release timings on a shared CI runner vary by more
///    than an order of magnitude under load. A ceiling loose enough never to flake
///    there (say 50×) would no longer be a *measurement* — it would pass through a
///    genuine regression. A ceiling tight enough to catch one would flake.
/// 2. The owner's bar is "measure, don't assume": the deliverable is the *number*, read
///    off a controlled run, not a pass/fail bit. Gating keeps the numbers reproducible
///    (a dedicated run on a quiet machine) while guaranteeing CI never executes them.
///
/// So CI (which never sets `BUZZKIT_PERF`) skips these entirely and stays green; a
/// deliberate `BUZZKIT_PERF=1 make test` prints the numbers. Correctness invariants the
/// measurements happen to prove — every event ingested, only the gap fetched — are
/// asserted regardless, and a deliberately loose ceiling (documented per test) guards
/// against a pathological regression when the suite *is* run.
enum Perf {
    /// Whether the performance suites should run. Mirrors the live suite's gating.
    static let enabled = ProcessInfo.processInfo.environment["BUZZKIT_PERF"] != nil

    /// Times an async body, returning its value and the elapsed wall seconds.
    static func measure<T>(_ body: () async throws -> T) async rethrows -> (value: T, seconds: Double) {
        let clock = ContinuousClock()
        let start = clock.now
        let value = try await body()
        return (value, seconds(since: start, on: clock))
    }

    /// Elapsed seconds from `start` to now on `clock`, as a `Double`.
    static func seconds(since start: ContinuousClock.Instant, on clock: ContinuousClock) -> Double {
        let elapsed = clock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    /// Prints one measurement line with a stable `[PERF]` prefix so a run's numbers are
    /// greppable out of the test log.
    static func report(_ label: String, _ detail: String) {
        print("[PERF] \(label): \(detail)")
    }
}

/// A signed-event generator for the performance suites — one author key, so the setup
/// cost is signing and nothing else, and the events are indistinguishable from wire
/// events at the ingest choke point.
///
/// Signing is fanned across a task group: a Schnorr signature is CPU-bound, and a
/// ten-thousand-event corpus signed serially would dominate an env-gated run's wall
/// time for no measurement benefit. The key is `Sendable`, so sharing it across the
/// group is safe.
struct PerfCorpus {
    let author: Fixture

    init() throws {
        author = try Fixture()
    }

    /// Signs `count` plain channel messages spread round-robin across `channels`, with
    /// strictly increasing `created_at`, in parallel. Order in the returned array is the
    /// signing index, so timestamps ascend with position.
    func messages(count: Int, channels: [String], startAt: Int64 = 1_700_000_000) async throws -> [NostrEvent] {
        let author = author
        return try await withThrowingTaskGroup(of: (Int, NostrEvent).self) { group in
            for index in 0 ..< count {
                let channel = channels[index % channels.count]
                let seconds = startAt + Int64(index)
                group.addTask {
                    (index, try author.event(.channelMessage, "m\(index)", tags: [["h", channel]], at: seconds))
                }
            }
            var events = [NostrEvent?](repeating: nil, count: count)
            for try await (index, event) in group {
                events[index] = event
            }
            return events.compactMap { $0 }
        }
    }

    /// A reply to `root` in `channel`, NIP-10 marked so the projector writes a thread row.
    func reply(to root: NostrEvent, in channel: String, index: Int, at seconds: Int64) throws -> NostrEvent {
        try author.event(
            .channelMessage, "reply\(index)",
            tags: [["h", channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }

    /// An authorized edit of `target`, so the timeline resolves content through it.
    func edit(of target: NostrEvent, to content: String, at seconds: Int64) throws -> NostrEvent {
        try author.event(.messageEdit, content, tags: [["e", target.id]], at: seconds)
    }

    /// An author deletion of `target`, applied at read time.
    func deletion(of target: NostrEvent, at seconds: Int64) throws -> NostrEvent {
        try author.event(.deletion, "", tags: [["e", target.id]], at: seconds)
    }
}
