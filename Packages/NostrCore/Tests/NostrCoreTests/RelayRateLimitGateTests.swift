import Foundation
@testable import NostrCore
import Testing

/// Spins until `condition` holds or the deadline passes, and reports which.
///
/// The suite's own `waitUntil` spins forever, so a regression in a test that waits for a frame
/// hangs the run instead of failing it — `.timeLimit` cannot interrupt a `Task.yield()` loop that
/// never checks cancellation. Bounded here so a broken retry path costs a second and a red test
/// rather than a stalled CI job.
func holds(within timeout: Duration = .seconds(5), _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// A clock a test advances by hand, so a 300-second window is asserted in microseconds.
private final class PinnedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ start: Date = Date(timeIntervalSince1970: 1_000_000)) { value = start }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

@Suite("RelayRateLimitGate: windows that extend but never shrink")
struct RelayRateLimitGateTests {
    private func makeGate(_ clock: PinnedClock) -> RelayRateLimitGate {
        // The expiry task never fires on its own; every test drives expiry through the clock, so
        // there is no real time to wait on and no race between the sleep and the assertion.
        RelayRateLimitGate(now: { clock.now }, sleepFor: { _ in try await Task.sleep(for: .seconds(3600)) })
    }

    @Test("A refusal with no hint opens the default window")
    func defaultWindow() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)

        #expect(await gate.isActive == false)
        await gate.activate(retryInSeconds: nil)
        #expect(await gate.isActive)

        clock.advance(TimeInterval(RelayRateLimitGate.defaultRetrySeconds) - 1)
        #expect(await gate.isActive)
        clock.advance(2)
        #expect(await gate.isActive == false)
    }

    @Test("The relay's hint sets the window, and an absurd one is clamped")
    func hintSetsAndClamps() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)

        await gate.activate(retryInSeconds: 30)
        clock.advance(29)
        #expect(await gate.isActive)
        clock.advance(2)
        #expect(await gate.isActive == false)

        await gate.activate(retryInSeconds: 9999)
        clock.advance(TimeInterval(RelayRateLimitGate.maxRetrySeconds) - 1)
        #expect(await gate.isActive)
        clock.advance(2)
        #expect(await gate.isActive == false)
    }

    @Test("A shorter second refusal cannot undercut the window already open")
    func neverShrinks() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)

        await gate.activate(retryInSeconds: 60)
        // Two more refusals arriving behind the first, both asking for less. If either won, every
        // waiter would be released early — straight back into the budget that just refused them.
        await gate.activate(retryInSeconds: 5)
        await gate.activate(retryInSeconds: nil)

        clock.advance(59)
        #expect(await gate.isActive)
        clock.advance(2)
        #expect(await gate.isActive == false)
    }

    @Test("A longer refusal extends the window")
    func extends() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)

        await gate.activate(retryInSeconds: 10)
        clock.advance(5)
        await gate.activate(retryInSeconds: 60)

        clock.advance(10) // past the original window
        #expect(await gate.isActive)
        clock.advance(60)
        #expect(await gate.isActive == false)
    }

    @Test("Waiting on an inactive gate does not suspend", .timeLimit(.minutes(1)))
    func waitOnInactiveReturns() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)
        await gate.wait() // would hang the test if it suspended
    }

    @Test("Reset releases every waiter at once", .timeLimit(.minutes(1)))
    func resetReleasesWaiters() async {
        let clock = PinnedClock()
        let gate = makeGate(clock)
        await gate.activate(retryInSeconds: 300)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 3 {
                group.addTask { await gate.wait() }
            }
            // Let the waiters suspend before the reset, so this asserts the release path rather
            // than the never-suspended shortcut above.
            try? await Task.sleep(for: .milliseconds(20))
            await gate.reset()
            await group.waitForAll()
        }
        #expect(await gate.isActive == false)
    }

    // MARK: - Retry hint parsing

    @Test("The relay's `retry in Ns` hint is read off a rate-limited message only")
    func parsesRetryHint() {
        #expect(OKReason(message: "rate-limited: slow down, retry in 30s").retryAfterSeconds == 30)
        #expect(OKReason(message: "rate-limited: RETRY IN 7S please").retryAfterSeconds == 7)
        #expect(OKReason(message: "rate-limited: too many requests").retryAfterSeconds == nil)
        // A digit-bearing message that is not a rate limit must not be mined for one.
        #expect(OKReason(message: "error: retry in 5s").retryAfterSeconds == nil)
    }

    @Test("The two error messages a retry can never satisfy are terminal")
    func terminalErrors() {
        #expect(OKReason(message: "error: too many subscriptions").disposition == .terminal)
        #expect(OKReason(message: "error: mixed search is not supported").disposition == .terminal)
        // A generic server-side error is still worth another attempt.
        #expect(OKReason(message: "error: internal").disposition == .retryable)
        #expect(OKReason(message: "rate-limited: slow down").disposition == .retryable)
    }
}
