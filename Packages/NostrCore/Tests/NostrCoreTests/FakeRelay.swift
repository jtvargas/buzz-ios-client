import Foundation
@testable import NostrCore

/// A scripted relay standing in for a real socket.
///
/// The whole point of the ``RelayTransport`` seam: the protocol layers above
/// run against this with no network, no server, and no timing flakiness. Tests
/// hand it a script of frames to deliver, read back everything the client sent,
/// and arm precise failures — a refused connect, a broken send, a read that
/// hangs and then errors, a mid-stream disconnect.
///
/// Determinism comes from continuations, never sleeps. A ``receive()`` with
/// nothing scripted parks on a continuation; a later ``enqueue(_:)`` or
/// ``enqueueFailure(_:)`` resumes it. Because there is exactly one delivery per
/// pull and one consumer, the *outcome* of a test does not depend on whether
/// the script arrives before or after the receiver parks.
actor FakeRelay: RelayTransport {
    /// One scripted delivery for a single ``receive()`` pull: a frame or a
    /// failure that ends the read.
    private enum Delivery {
        case frame(String)
        case failure(TransportError)
    }

    // MARK: Recorded interactions

    /// Every URL passed to ``connect(url:)``, in order.
    private(set) var connectAttempts: [URL] = []
    /// Every frame the client successfully sent, in order.
    private(set) var sentFrames: [String] = []
    /// How many times ``ping()`` was called.
    private(set) var pingCount = 0
    /// Whether the socket has been closed.
    private(set) var isClosed = false

    // MARK: Scripted behaviour

    private var connectFailure: TransportError?
    private var sendFailure: TransportError?
    private var pending: [Delivery] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var lastActivity: ContinuousClock.Instant?

    // MARK: - RelayTransport

    func connect(url: URL) async throws {
        connectAttempts.append(url)
        if let connectFailure { throw connectFailure }
        isClosed = false
    }

    func send(_ text: String) async throws {
        if let sendFailure { throw sendFailure }
        if isClosed { throw TransportError.connectionClosed }
        sentFrames.append(text)
    }

    func send(_ data: Data) async throws {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw TransportError.sendFailed("frame was not valid UTF-8")
        }
        try await send(text)
    }

    func receive() async throws -> String {
        if !pending.isEmpty {
            return try consume(pending.removeFirst())
        }
        // A closed socket never delivers again — surface it rather than parking
        // a read that could never be resumed (this also makes "close unblocks a
        // read" race-free whichever side wins).
        if isClosed {
            throw TransportError.connectionClosed
        }
        // Pull-based: nothing is delivered until the script provides it. Park
        // on a continuation rather than polling so there is no timing to race.
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func ping() async throws {
        pingCount += 1
        if isClosed { throw TransportError.connectionClosed }
        markActivity()
    }

    func close() {
        isClosed = true
        // Mirror the real socket: a suspended read is unblocked when the
        // connection goes away.
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: TransportError.connectionClosed)
        }
    }

    func lastReceivedAt() -> ContinuousClock.Instant? {
        lastActivity
    }

    func idleInterval() -> Duration? {
        lastActivity.map { ContinuousClock.now - $0 }
    }

    // MARK: - Test control

    /// Scripts one frame to be handed to the next ``receive()`` pull.
    func enqueue(_ frame: String) {
        deliver(.frame(frame))
    }

    /// Scripts a batch of frames, delivered one per pull in order.
    func enqueue(_ frames: [String]) {
        for frame in frames {
            deliver(.frame(frame))
        }
    }

    /// Scripts a failure to end the next ``receive()`` pull — a mid-stream
    /// disconnect (``TransportError/connectionClosed``) or a read error.
    func enqueueFailure(_ error: TransportError) {
        deliver(.failure(error))
    }

    /// Arms ``connect(url:)`` to throw.
    func failConnect(with error: TransportError) {
        connectFailure = error
    }

    /// Arms every ``send(_:)`` to throw until cleared.
    func failSends(with error: TransportError) {
        sendFailure = error
    }

    /// Clears an armed send failure.
    func recoverSends() {
        sendFailure = nil
    }

    /// How many scripted deliveries are buffered and not yet pulled. A test can
    /// assert this is zero to prove nothing was delivered beyond the script.
    var pendingCount: Int {
        pending.count
    }

    // MARK: - Internals

    private func deliver(_ delivery: Delivery) {
        guard let waiter else {
            pending.append(delivery)
            return
        }
        self.waiter = nil
        // Route the delivery through the same consume path a pull would take,
        // so a frame updates activity and a failure throws — resuming the
        // continuation exactly once either way.
        do {
            try waiter.resume(returning: consume(delivery))
        } catch {
            waiter.resume(throwing: error)
        }
    }

    private func consume(_ delivery: Delivery) throws -> String {
        switch delivery {
        case let .frame(text):
            markActivity()
            return text
        case let .failure(error):
            throw error
        }
    }

    private func markActivity() {
        lastActivity = ContinuousClock.now
    }
}
