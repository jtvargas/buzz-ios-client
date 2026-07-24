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

    // MARK: - RelayTransport

    public func connect(url: URL) async throws {
        // Tear down any prior socket first, or its read loop would race the new
        // one for frames.
        close()

        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

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
            message = try await task.receive()
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

    public func ping() async throws {
        guard task != nil else { throw TransportError.connectionClosed }
        try await probeOpen()
        markActivity()
    }

    public func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
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
    /// `URLSessionWebSocketTask.sendPing` fires its handler exactly once, on the
    /// pong or on failure. Wrapping it in a cancellation handler makes the
    /// suspension respond to `Task` cancellation: cancelling the socket forces
    /// the pending handler to fire with an error, which is how the open-timeout
    /// race unblocks the probe when the deadline wins.
    private func probeOpen() async throws {
        guard let task else { throw TransportError.connectionClosed }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                task.sendPing { error in
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
