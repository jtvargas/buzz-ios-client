import Foundation
@testable import Hive
import NostrCore

/// Records the ephemeral events a heartbeat or a typing sender would publish, so the
/// send shape and cadence are asserted without a live engine or any real time.
actor RecordingEphemeralPublisher: EphemeralPublishing {
    struct Publish: Equatable {
        let kind: EventKind
        let content: String
        let tags: [[String]]
    }

    private(set) var publishes: [Publish] = []

    func publishEphemeral(kind: EventKind, content: String, tags: [[String]]) async {
        publishes.append(Publish(kind: kind, content: content, tags: tags))
    }

    var count: Int { publishes.count }
    func online() -> Int { publishes.filter { $0.content == "online" }.count }
    func offline() -> Int { publishes.filter { $0.content == "offline" }.count }
}

/// A hand-advanced monotonic clock, so a throttle window is driven deterministically
/// with no sleeps and no real time. The BuzzKit test suite's `MutableClock`, copied
/// per the duplicate-the-harness precedent.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var current: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

/// A cadence-sleep stand-in that permits a fixed number of ticks and then throws, so
/// a heartbeat's beat loop self-terminates at a known count — the cadence is asserted
/// without a timer or real time.
actor TickGate {
    private var remaining: Int

    init(allowed: Int) {
        remaining = allowed
    }

    /// Returns for the first `allowed` calls, then throws to end the loop.
    func tick() async throws {
        if remaining <= 0 { throw CancellationError() }
        remaining -= 1
    }
}
