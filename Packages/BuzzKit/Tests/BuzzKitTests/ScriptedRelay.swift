import Foundation
import NostrCore

/// A scripted relay socket for the engine suites, built against NostrCore's
/// **public** ``RelayTransport`` protocol only — no `@testable` internals — so it
/// lives here in BuzzKit's test target rather than reaching into NostrCore.
///
/// It is a deliberate re-implementation of the same continuation-based determinism
/// NostrCore's own `FakeRelay` proves: a ``receive()`` with nothing scripted parks
/// on a continuation, and a later ``enqueue(_:)`` / ``enqueueFailure(_:)`` resumes
/// it, so a test's outcome never depends on whether the script arrives before or
/// after the reader parks. Tests read back every frame the client sent to drive
/// the auth handshake, answer REQs, and assert the wire.
actor ScriptedRelay: RelayTransport {
    private enum Delivery {
        case frame(String)
        case failure(TransportError)
    }

    private(set) var connectAttempts: [URL] = []
    private(set) var sentFrames: [String] = []
    private(set) var isClosed = false

    private var connectFailure: TransportError?
    private var pingFailure: TransportError?
    private var pending: [Delivery] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var lastActivity: ContinuousClock.Instant?
    private var sendWaiters: [Int: [CheckedContinuation<String, Never>]] = [:]

    // MARK: - RelayTransport

    func connect(url: URL) async throws {
        connectAttempts.append(url)
        if let connectFailure { throw connectFailure }
        isClosed = false
    }

    func send(_ text: String) async throws {
        if isClosed { throw TransportError.connectionClosed }
        sentFrames.append(text)
        let index = sentFrames.count - 1
        if let waiters = sendWaiters.removeValue(forKey: index) {
            for waiter in waiters { waiter.resume(returning: text) }
        }
    }

    func send(_ data: Data) async throws {
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw TransportError.sendFailed("frame was not valid UTF-8")
        }
        try await send(text)
    }

    func receive() async throws -> String {
        if !pending.isEmpty { return try consume(pending.removeFirst()) }
        if isClosed { throw TransportError.connectionClosed }
        return try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
        }
    }

    func ping() async throws {
        if let pingFailure { throw pingFailure }
        if isClosed { throw TransportError.connectionClosed }
        markActivity()
    }

    func close() {
        isClosed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: TransportError.connectionClosed)
        }
    }

    func lastReceivedAt() -> ContinuousClock.Instant? { lastActivity }

    func idleInterval() -> Duration? {
        lastActivity.map { ContinuousClock.now - $0 }
    }

    // MARK: - Test control

    func enqueue(_ frame: String) { deliver(.frame(frame)) }

    func enqueue(_ frames: [String]) {
        for frame in frames { deliver(.frame(frame)) }
    }

    func enqueueFailure(_ error: TransportError) { deliver(.failure(error)) }

    func failConnect(with error: TransportError) { connectFailure = error }

    /// Arms ``ping()`` to throw, standing in for a peer that has silently gone away
    /// — the frozen-then-dead socket a foreground liveness probe must catch.
    func failPings(with error: TransportError) { pingFailure = error }

    /// Suspends until the client has sent at least `index + 1` frames, returning the
    /// frame at `index`.
    func awaitSend(index: Int) async -> String {
        if index < sentFrames.count { return sentFrames[index] }
        return await withCheckedContinuation { continuation in
            sendWaiters[index, default: []].append(continuation)
        }
    }

    /// A snapshot of every frame the client has sent so far.
    func frames() -> [String] { sentFrames }

    // MARK: - Internals

    private func deliver(_ delivery: Delivery) {
        guard let waiter else {
            pending.append(delivery)
            return
        }
        self.waiter = nil
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

/// Vends ``ScriptedRelay`` instances to a ``RelayConnection``'s transport factory
/// in a scripted order, so a reconnect test controls each successive socket. Extra
/// pulls past the scripted list get fresh, benign sockets.
actor ScriptedTransportQueue {
    private var relays: [ScriptedRelay]
    private(set) var vendedCount = 0

    init(_ relays: [ScriptedRelay]) {
        self.relays = relays
    }

    func next() -> ScriptedRelay {
        if vendedCount < relays.count {
            let relay = relays[vendedCount]
            vendedCount += 1
            return relay
        }
        let relay = ScriptedRelay()
        relays.append(relay)
        vendedCount += 1
        return relay
    }
}

// MARK: - Frame builders

/// Raw relay-to-client frames, matching the wire shapes ``RelayMessage`` decodes.
enum EngineFrames {
    static func challenge(_ token: String) -> String {
        #"["AUTH","\#(token)"]"#
    }

    static func ok(_ eventID: String, _ accepted: Bool, _ message: String = "") -> String {
        #"["OK","\#(eventID)",\#(accepted ? "true" : "false"),"\#(message)"]"#
    }

    static func eose(_ subscriptionID: String) -> String {
        #"["EOSE","\#(subscriptionID)"]"#
    }

    static func closed(_ subscriptionID: String, _ message: String = "") -> String {
        #"["CLOSED","\#(subscriptionID)","\#(message)"]"#
    }

    static func event(_ subscriptionID: String, _ event: NostrEvent) -> String {
        guard let data = try? JSONEncoder().encode(event),
              let json = String(bytes: data, encoding: .utf8)
        else {
            return #"["EVENT","\#(subscriptionID)",{}]"#
        }
        return #"["EVENT","\#(subscriptionID)",\#(json)]"#
    }
}

// MARK: - Client-frame parsing

enum EngineFrameError: Error {
    case notAuth(String)
    case notReq(String)
    case notEvent(String)
}

/// The id of the auth event inside an `["AUTH", {event}]` frame the client sent.
func authEventID(from frame: String) throws -> String {
    guard case let .auth(event) = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8)) else {
        throw EngineFrameError.notAuth(frame)
    }
    return event.id
}

/// The `(subscriptionID, filters)` of a `["REQ", id, ...]` frame, or `nil` if the
/// frame is not a REQ.
func decodeREQ(_ frame: String) -> (id: String, filters: [Filter])? {
    guard case let .req(id, filters) = try? JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8)) else {
        return nil
    }
    return (id, filters)
}

/// The event id of an `["EVENT", {event}]` publish frame, or `nil` otherwise.
func publishedEventID(_ frame: String) -> String? {
    guard case let .event(event) = try? JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8)) else {
        return nil
    }
    return event.id
}
