import Foundation

/// Exponential backoff with full jitter, plus a health-based counter reset.
///
/// A pure value with no clock and no random source of its own: the schedule is a
/// function of the attempt number and a caller-supplied jitter fraction, so every
/// branch can be asserted in a test without waiting for real time or fighting a
/// non-deterministic generator. ``RelayConnection`` owns the clock and the RNG
/// and feeds them in.
///
/// # Full jitter
///
/// The delay for an attempt is a uniform draw from `0 ... ceiling`, where the
/// ceiling grows exponentially and is clamped at ``cap``. Spreading the delay
/// across the whole window — rather than jittering a fixed backoff by a few
/// percent — is what stops every client of a relay that just restarted from
/// coming back in the same instant and knocking it over again.
///
/// # Wired `resetAfter`
///
/// Exponential backoff without a reset punishes a connection for its history: a
/// link that reconnects cleanly once an hour would still wait the maximum delay
/// after a week of uptime, because the attempt counter only ever climbs. A
/// connection that stayed healthy for at least ``resetAfter`` is treated as a
/// fresh start, so its next failure begins counting from one again. The policy
/// only states the rule (``isHealthy(afterUpFor:)``); the connection measures the
/// uptime and applies it.
public struct ReconnectPolicy: Sendable, Equatable {
    /// The first attempt's ceiling, doubled each subsequent attempt.
    public let base: Duration
    /// The largest ceiling any attempt may reach, regardless of how many have
    /// failed.
    public let cap: Duration
    /// How long a connection must stay up to earn a reset of the attempt counter
    /// on its next failure.
    public let resetAfter: Duration

    public init(
        base: Duration = .seconds(1),
        cap: Duration = .seconds(30),
        resetAfter: Duration = .seconds(30)
    ) {
        self.base = base
        self.cap = cap
        self.resetAfter = resetAfter
    }

    public static let `default` = ReconnectPolicy()

    /// The delay before `attempt` (counted from 1) given a jitter `fraction` in
    /// `0...1`.
    ///
    /// The ceiling is `min(cap, base · 2^(attempt−1))`; the returned delay is
    /// `ceiling · fraction`. Passing a fraction lets a test pin the exact delay
    /// (0 for the floor, 1 for the ceiling, 0.5 for the midpoint) while
    /// production feeds a random draw. A fraction outside `0...1` is clamped so a
    /// misbehaving source can never produce a negative or over-cap delay.
    public func delay(forAttempt attempt: Int, fraction: Double) -> Duration {
        guard attempt > 0 else { return .zero }

        // Cap the exponent well before `Double` loses integer precision, so a
        // pathologically long outage cannot overflow the ceiling into nonsense.
        let exponent = min(attempt - 1, 16)
        let ceiling = min(base * pow(2.0, Double(exponent)), cap)
        let clamped = min(max(fraction, 0), 1)
        return ceiling * clamped
    }

    /// The delay before `attempt`, drawing the jitter fraction from `rng`.
    ///
    /// Takes the generator `inout` so a seeded generator threads through a test
    /// run and reproduces the exact schedule.
    public func delay(forAttempt attempt: Int, using rng: inout some RandomNumberGenerator) -> Duration {
        delay(forAttempt: attempt, fraction: .random(in: 0 ... 1, using: &rng))
    }

    /// The delay before `attempt`, drawing jitter from the system CSPRNG.
    public func delay(forAttempt attempt: Int) -> Duration {
        var rng = SystemRandomNumberGenerator()
        return delay(forAttempt: attempt, using: &rng)
    }

    /// Whether a connection that stayed up for `uptime` counts as healthy enough
    /// to reset the attempt counter on its next failure.
    public func isHealthy(afterUpFor uptime: Duration) -> Bool {
        uptime >= resetAfter
    }
}
