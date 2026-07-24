import Foundation
@testable import NostrCore
import Testing

@Suite("ReconnectPolicy full-jitter backoff")
struct ReconnectPolicyTests {
    // MARK: - Jitter bounds

    @Test("A zero fraction yields the floor, a full fraction yields the ceiling")
    func fractionEndpoints() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))

        // Attempt 3's ceiling is base · 2^2 = 4s.
        #expect(policy.delay(forAttempt: 3, fraction: 0) == .zero)
        #expect(policy.delay(forAttempt: 3, fraction: 1) == .seconds(4))
        #expect(policy.delay(forAttempt: 3, fraction: 0.5) == .seconds(2))
    }

    @Test("The ceiling doubles each attempt until it reaches the cap")
    func exponentialCeiling() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))

        // A full-fraction draw exposes the ceiling directly.
        #expect(policy.delay(forAttempt: 1, fraction: 1) == .seconds(1))
        #expect(policy.delay(forAttempt: 2, fraction: 1) == .seconds(2))
        #expect(policy.delay(forAttempt: 3, fraction: 1) == .seconds(4))
        #expect(policy.delay(forAttempt: 4, fraction: 1) == .seconds(8))
        #expect(policy.delay(forAttempt: 5, fraction: 1) == .seconds(16))
    }

    @Test("The ceiling is clamped at the cap and never exceeds it")
    func capIsRespected() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))

        // 2^5 = 32s > 30s cap.
        #expect(policy.delay(forAttempt: 6, fraction: 1) == .seconds(30))
        // A pathologically long outage does not overflow the ceiling into
        // nonsense; the exponent is clamped and the cap holds.
        #expect(policy.delay(forAttempt: 1000, fraction: 1) == .seconds(30))
    }

    @Test("Attempt 0 or below has no delay")
    func nonPositiveAttempt() {
        let policy = ReconnectPolicy.default
        #expect(policy.delay(forAttempt: 0, fraction: 1) == .zero)
        #expect(policy.delay(forAttempt: -5, fraction: 1) == .zero)
    }

    @Test("A fraction outside 0...1 is clamped, never producing a negative or over-cap delay")
    func fractionIsClamped() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))
        #expect(policy.delay(forAttempt: 3, fraction: -1) == .zero)
        #expect(policy.delay(forAttempt: 3, fraction: 2) == .seconds(4))
    }

    // MARK: - Injected RNG

    @Test("Every random draw stays within the attempt's ceiling")
    func randomDrawsStayBounded() {
        let policy = ReconnectPolicy(base: .seconds(1), cap: .seconds(30))
        var rng = SeededGenerator(seed: 0xDEAD_BEEF)

        for attempt in 1 ... 12 {
            let ceiling = min(Duration.seconds(1) * pow(2.0, Double(min(attempt - 1, 16))), .seconds(30))
            for _ in 0 ..< 50 {
                let delay = policy.delay(forAttempt: attempt, using: &rng)
                #expect(delay >= .zero)
                #expect(delay <= ceiling)
            }
        }
    }

    @Test("A seeded generator reproduces the exact schedule")
    func seededScheduleIsReproducible() {
        let policy = ReconnectPolicy.default

        var first = SeededGenerator(seed: 42)
        var second = SeededGenerator(seed: 42)

        let scheduleA = (1 ... 20).map { policy.delay(forAttempt: $0, using: &first) }
        let scheduleB = (1 ... 20).map { policy.delay(forAttempt: $0, using: &second) }

        #expect(scheduleA == scheduleB)
    }

    // MARK: - resetAfter

    @Test("A connection up at least resetAfter is healthy; a shorter one is not")
    func healthThreshold() {
        let policy = ReconnectPolicy(resetAfter: .seconds(30))

        #expect(policy.isHealthy(afterUpFor: .seconds(30)))
        #expect(policy.isHealthy(afterUpFor: .seconds(31)))
        #expect(!policy.isHealthy(afterUpFor: .seconds(29)))
        #expect(!policy.isHealthy(afterUpFor: .zero))
    }
}
