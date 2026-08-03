import Foundation

/// The session-wide pause a relay's `rate-limited:` verdict buys.
///
/// A Buzz relay budgets requests (50 `REQ` per 5 seconds at the time of writing) and answers an
/// over-budget subscription with `CLOSED rate-limited: …`, often carrying its own `retry in Ns`
/// hint. Without somewhere to record that, every caller learns the same lesson separately and
/// keeps pushing: the refusal arrives, something retries, the retry is refused. One gate per
/// session is what turns "this request was refused" into "this *connection* is over budget", so a
/// refusal on one subscription slows every other request behind it rather than only its own.
///
/// # Extend, never shrink
///
/// ``activate(retryInSeconds:)`` moves the deadline out and never pulls it in. Two refusals
/// arriving together would otherwise let the second — with a shorter hint, or none at all —
/// undercut the first and release everybody early, straight back into the budget that just
/// refused them. The longest window any relay asked for is the one that holds.
///
/// # Injected clock
///
/// No clock and no timer of its own, on ``ReconnectPolicy``'s principle: the caller supplies
/// `now` and the sleep, so a test drives an expiry by advancing a value instead of waiting on
/// real seconds. Production passes the system clock and `Task.sleep`.
public actor RelayRateLimitGate {
    /// The window used when a relay refuses without naming a duration. Upstream's mobile client
    /// uses the same ten seconds; a refusal with no hint still has to cost *something*, or the
    /// retry is indistinguishable from not having a gate at all.
    public static let defaultRetrySeconds = 10
    /// The longest hint honoured. A relay asking for an hour is more likely misconfigured than
    /// serious, and a client that obeys it looks indistinguishable from a hung one.
    public static let maxRetrySeconds = 300

    private let now: @Sendable () -> Date
    private let sleepFor: @Sendable (Duration) async throws -> Void

    /// When the current window ends, or `nil` when no window is open.
    private var expiresAt: Date?
    /// Everyone waiting on the current window. Resumed together when it ends — they were all
    /// refused by the same budget, so they are all released by the same clock.
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// The task counting down the current window, cancelled whenever the window is replaced.
    private var expiryTask: Task<Void, Never>?

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        sleepFor: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.now = now
        self.sleepFor = sleepFor
    }

    /// Whether a window is open right now.
    public var isActive: Bool {
        guard let expiresAt else { return false }
        return now() < expiresAt
    }

    /// What is left of the current window, or zero when none is open.
    public var remaining: Duration {
        guard let expiresAt else { return .zero }
        let seconds = expiresAt.timeIntervalSince(now())
        return seconds > 0 ? .seconds(seconds) : .zero
    }

    /// Opens a window, or extends the open one.
    ///
    /// `retryInSeconds` is the relay's own hint; `nil` or a non-positive value falls back to
    /// ``defaultRetrySeconds``, and anything above ``maxRetrySeconds`` is clamped to it. A window
    /// that would end no later than the current one is ignored — see the type doc.
    public func activate(retryInSeconds: Int?) {
        let seconds = if let retryInSeconds, retryInSeconds > 0 {
            min(retryInSeconds, Self.maxRetrySeconds)
        } else {
            Self.defaultRetrySeconds
        }
        let deadline = now().addingTimeInterval(TimeInterval(seconds))
        if let expiresAt, deadline <= expiresAt { return }

        expiresAt = deadline
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await self?.sleepFor(.seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.expire(deadline)
        }
    }

    /// Suspends until the current window ends. Returns immediately when none is open.
    public func wait() async {
        guard isActive else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Ends any window at once and releases every waiter.
    ///
    /// Called when the socket drops: the refusals belonged to a connection that no longer exists,
    /// and a fresh one is not over budget until it says so itself.
    public func reset() {
        expiryTask?.cancel()
        expiryTask = nil
        expiresAt = nil
        release()
    }

    /// Ends the window this expiry was scheduled for. A stale timer — one whose window was
    /// already replaced by a longer one — is ignored rather than releasing waiters early.
    private func expire(_ deadline: Date) {
        guard expiresAt == deadline else { return }
        expiryTask = nil
        expiresAt = nil
        release()
    }

    private func release() {
        let resumed = waiters
        waiters.removeAll()
        for continuation in resumed { continuation.resume() }
    }
}
