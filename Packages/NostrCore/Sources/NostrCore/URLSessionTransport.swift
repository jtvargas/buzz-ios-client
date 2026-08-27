import Foundation

/// The production ``RelayTransport`` over `URLSessionWebSocketTask`.
///
/// Beyond the plain four-operation pipe it adds the two guards a long-lived
/// relay connection cannot go without, neither of which `URLSession` gives for
/// free:
///
/// - **Open timeout.** A websocket to a black-holed address will sit in a TCP
///   connect (or a half-finished HTTP upgrade) for the OS's own patience —
///   often a minute or more. ``connect(url:)`` bounds this: it opens the task
///   and, in the same step, round-trips a ping; the ping can only complete once
///   the upgrade is done and the peer has answered, so a pong within the
///   deadline is proof the connection is genuinely up, while the deadline
///   expiring throws ``TransportError/connectTimeout``. One primitive
///   establishes *and* liveness-checks the socket.
///
/// - **Heartbeat mechanic.** ``ping()`` exposes the same round-trip for the
///   read-idle watchdog the owner drives, and ``lastReceivedAt()`` /
///   ``idleInterval()`` report inbound activity so the owner knows when to use
///   it. A received frame and an answered ping both count as activity — the
///   watchdog only needs to prove the peer is still there.
public actor URLSessionTransport: RelayTransport {
    private let session: URLSession
    private let openTimeout: Duration
    private var task: URLSessionWebSocketTask?
    private var lastActivity: ContinuousClock.Instant?
    /// What became of the read the open probe armed. `URLSession` queues receive
    /// completions and delivers them in order, so this read owns the socket's
    /// **next** frame whether or not the probe still cares about it — see
    /// ``probeOpen()``.
    private var probeRead: ProbeRead = .none
    /// A ``receive()`` parked because the probe's read owns the next frame. It is
    /// resumed by ``settleProbeReceive(_:generation:once:continuation:)``; arming
    /// a second read here instead is what used to lose a frame.
    private var parkedReader: CheckedContinuation<URLSessionWebSocketTask.Message, Error>?
    /// Bumped by every ``connect(url:)``, so a probe read left over from a socket
    /// this transport has moved on from is recognised and discarded.
    private var connectGeneration: UInt64 = 0

    /// The lifecycle of the read armed by ``probeOpen()``.
    private enum ProbeRead {
        /// No probe read is outstanding — ``receive()`` reads the socket itself.
        case none
        /// Armed and not yet completed: it, not a fresh read, will carry the
        /// next frame.
        case outstanding
        /// Completed with nobody waiting. The next ``receive()`` takes this.
        case settled(Result<URLSessionWebSocketTask.Message, any Error>)
    }

    /// - Parameters:
    ///   - session: the session to open tasks on; injectable for tests.
    ///   - openTimeout: how long ``connect(url:)`` waits for the socket to open
    ///     and the peer to answer before giving up. ~10s suits a relay reached
    ///     over a mobile network without punishing a genuinely slow-but-alive
    ///     path.
    public init(session: URLSession = .shared, openTimeout: Duration = .seconds(10)) {
        self.session = session
        self.openTimeout = openTimeout
    }

    /// The largest inbound websocket message this transport will accept, 8 MiB against
    /// `URLSession`'s 1 MiB default. Sized so a roster snapshot cannot kill the socket —
    /// see ``connect(url:)``.
    static let maximumMessageSize = 8 * 1_024 * 1_024

    // MARK: - RelayTransport

    public func connect(url: URL) async throws {
        // Tear down any prior socket first, or its read loop would race the new
        // one for frames.
        close()

        let task = session.webSocketTask(with: url)
        // `URLSessionWebSocketTask` defaults to a 1 MiB ceiling, and a frame over it is
        // not truncated — the read fails and takes the socket with it, which this
        // connection then treats as a disconnect and reconnects into the same frame.
        //
        // One kind of frame can genuinely grow past 1 MiB: a channel roster snapshot,
        // which carries a `p` tag per member at roughly 85 bytes each. That is a live
        // ceiling at around 11-12k members. The largest channel we know of is a couple of
        // thousand, so this is headroom rather than a fix for something reported — but the
        // failure it prevents is a dead socket rather than a short list, and the cost of
        // the headroom is only that a frame this large would be buffered if one arrived.
        task.maximumMessageSize = Self.maximumMessageSize
        self.task = task
        task.resume()
        // Every socket gets its own generation, so a read armed on an abandoned
        // one cannot hand its frame — or its closing error — to this one.
        connectGeneration &+= 1

        do {
            let deadline = openTimeout
            try await withThrowingTaskGroup(of: Void.self) { group in
                // The probe hops onto the actor and reads `self.task`; the task
                // object itself never crosses the concurrency boundary.
                group.addTask { [self] in try await probeOpen() }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw ConnectTimeout()
                }
                // Whichever finishes first decides the outcome; cancelling the
                // loser unblocks it (the ping via the socket, the sleep via
                // cooperative cancellation).
                try await group.next()
                group.cancelAll()
            }
        } catch is ConnectTimeout {
            cancel(task, with: .goingAway)
            throw TransportError.connectTimeout
        } catch {
            cancel(task, with: .abnormalClosure)
            throw TransportError.connectFailed(String(describing: error))
        }

        markActivity()
    }

    public func send(_ text: String) async throws {
        guard let task else { throw TransportError.connectionClosed }
        do {
            try await task.send(.string(text))
        } catch {
            throw TransportError.sendFailed(String(describing: error))
        }
    }

    public func send(_ data: Data) async throws {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw TransportError.sendFailed("frame was not valid UTF-8")
        }
        try await send(text)
    }

    public func receive() async throws -> String {
        guard let task else { throw TransportError.connectionClosed }

        let message: URLSessionWebSocketTask.Message
        do {
            message = try await nextMessage(task)
        } catch {
            throw TransportError.receiveFailed(String(describing: error))
        }
        markActivity()

        switch message {
        case let .string(text):
            return text
        case let .data(data):
            // Relays speak text, but a data frame that is valid UTF-8 decodes
            // cleanly and is worth tolerating rather than dropping.
            guard let text = String(bytes: data, encoding: .utf8) else {
                throw TransportError.unsupportedFrame
            }
            return text
        @unknown default:
            throw TransportError.unsupportedFrame
        }
    }

    /// The watchdog's liveness round-trip. Relies on the owner's read loop
    /// keeping a `receive()` pending — `URLSession` only pumps inbound frames,
    /// pongs included, while one is — which is always true post-connect. The
    /// connect-time probe cannot rely on that and uses ``probeOpen()`` instead.
    public func ping() async throws {
        guard let task else { throw TransportError.connectionClosed }
        let once = ResumeOnce()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelActiveTask() }
        }
        markActivity()
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        // The cancelled socket completes the probe's read with an error, which
        // resumes any parked reader through the ordinary path; what it cannot do
        // is clear a frame settled but never taken, which would otherwise be
        // replayed onto the *next* socket this transport opens.
        if case .settled = probeRead { probeRead = .none }
    }

    public func lastReceivedAt() -> ContinuousClock.Instant? {
        lastActivity
    }

    public func idleInterval() -> Duration? {
        lastActivity.map { ContinuousClock.now - $0 }
    }

    // MARK: - Internals

    /// Sends a ping and suspends until the pong — or an error — comes back.
    ///
    /// Proves the socket is genuinely open, bounded by the caller's deadline.
    ///
    /// Two hard-won facts about `URLSessionWebSocketTask` shape this (both
    /// observed against a live TLS relay):
    ///
    /// 1. Inbound frames — pongs included — are only pumped while a `receive`
    ///    is pending. A ping sent with no reader never completes, so the probe
    ///    arms its own receive. Against a relay that talks first (Buzz sends
    ///    its AUTH challenge on connect) the first frame doubles as the open
    ///    proof and is handed to the read loop; a silent relay is proven by
    ///    the pong the pending receive pumps.
    ///
    ///    In that second case the armed receive **outlives the probe**, and
    ///    `URLSession` serves queued receives in the order they were armed — so
    ///    it, not the read loop, is handed the first frame the relay ever sends.
    ///    That read therefore stays part of the read path (``ProbeRead``) rather
    ///    than being abandoned: it was once, and against a silent relay the
    ///    frame it swallowed was the `EOSE` a pairing session waits on, so
    ///    pairing hung on "Connecting to your desktop…" until it timed out.
    /// 2. A socket torn down mid-ping can fire the ping handler more than once
    ///    (send failure, then connection abort). Every resume path goes
    ///    through a once-guard, so whichever loses the race is a no-op.
    ///
    /// The cancellation handler keeps the suspension responsive to `Task`
    /// cancellation: cancelling the socket forces the pending handlers to fire
    /// with errors, which is how the open-timeout race unblocks the probe when
    /// the deadline wins.
    private func probeOpen() async throws {
        guard let task else { throw TransportError.connectionClosed }
        let once = ResumeOnce()
        let generation = connectGeneration
        probeRead = .outstanding
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.receive { result in
                    Task {
                        await self.settleProbeReceive(
                            result, generation: generation, once: once, continuation: continuation
                        )
                    }
                }
                task.sendPing { error in
                    guard once.claim() else { return }
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } onCancel: {
            Task { await self.cancelActiveTask() }
        }
    }

    /// Settles the probe's armed read.
    ///
    /// The result is handed to the read path **first** — to a parked
    /// ``receive()`` if one is waiting, otherwise held for the next one — and
    /// only then, if the ping has not already spoken, used to settle the probe
    /// itself. Handing it over first is what makes the frame impossible to lose:
    /// this read has already consumed the socket's next frame by the time it
    /// runs, so anything short of delivering it drops that frame on the floor.
    private func settleProbeReceive(
        _ result: Result<URLSessionWebSocketTask.Message, any Error>,
        generation: UInt64,
        once: ResumeOnce,
        continuation: CheckedContinuation<Void, Error>
    ) {
        // A read from a socket this transport has already replaced carries
        // nothing the current one should see — but its probe still has to be
        // let go, so only the hand-off is skipped.
        if generation == connectGeneration {
            if let reader = parkedReader {
                parkedReader = nil
                probeRead = .none
                reader.resume(with: result)
            } else {
                probeRead = .settled(result)
            }
        }

        guard once.claim() else { return }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }

    /// The socket's next frame, from whichever read owns it.
    ///
    /// While the probe's read is outstanding it owns that frame, so a caller
    /// parks here rather than arming a second read — two reads would be served
    /// in the order they were armed, which puts the frame in the probe's hands
    /// and leaves the caller waiting on the one after it.
    private func nextMessage(_ task: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        switch probeRead {
        case let .settled(result):
            probeRead = .none
            return try result.get()
        case .outstanding where parkedReader == nil:
            return try await withCheckedThrowingContinuation { continuation in
                parkedReader = continuation
            }
        case .outstanding:
            // A second concurrent reader has no claim on the probe's frame — the
            // owner drives one read loop — so it queues behind it, which is the
            // order `URLSession` would give it anyway.
            return try await task.receive()
        case .none:
            return try await task.receive()
        }
    }

    private func cancelActiveTask() {
        task?.cancel(with: .goingAway, reason: nil)
    }

    /// Cancels `task` and clears it only if it is still the active one, so a
    /// failed attempt cannot tear down a socket a later ``connect(url:)`` opened.
    private func cancel(_ task: URLSessionWebSocketTask, with code: URLSessionWebSocketTask.CloseCode) {
        task.cancel(with: code, reason: nil)
        if self.task === task {
            self.task = nil
        }
    }

    private func markActivity() {
        lastActivity = ContinuousClock.now
    }

    /// The open-timeout sentinel, private so it never leaks past ``connect(url:)``.
    private struct ConnectTimeout: Error {}
}

/// Claims the right to resume a continuation exactly once across racing
/// completion paths. Lock-based because the claimants run on arbitrary
/// URLSession queues, outside any actor.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func claim() -> Bool {
        lock.withLock {
            if resumed { return false }
            resumed = true
            return true
        }
    }
}
