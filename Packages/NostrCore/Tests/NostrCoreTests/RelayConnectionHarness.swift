import Foundation
@testable import NostrCore
import Testing

// MARK: - Transport vending

/// Hands ``FakeRelay`` instances to a ``RelayConnection``'s transport factory in
/// a scripted order, so a reconnect test controls each successive socket. Extra
/// pulls past the scripted list get fresh, benign fakes.
actor TransportQueue {
    private var relays: [FakeRelay]
    private(set) var vendedCount = 0

    init(_ relays: [FakeRelay]) {
        self.relays = relays
    }

    func next() -> FakeRelay {
        if vendedCount < relays.count {
            let relay = relays[vendedCount]
            vendedCount += 1
            return relay
        }
        let relay = FakeRelay()
        relays.append(relay)
        vendedCount += 1
        return relay
    }
}

// MARK: - Deterministic timing controls

/// A releasable/cancellable stand-in for a sleep, so a test drives a
/// background-grace or backoff timer by hand rather than by the wall clock.
actor Gate {
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var released = false

    /// Suspends until ``release()`` is called, or throws if the awaiting task is
    /// cancelled. The `Duration` is ignored — the gate, not time, decides.
    func wait(_: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if released {
                    continuation.resume()
                } else if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuations.append(continuation)
                }
            }
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    func release() {
        released = true
        let waiters = continuations
        continuations.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func cancelAll() {
        let waiters = continuations
        continuations.removeAll()
        for waiter in waiters {
            waiter.resume(throwing: CancellationError())
        }
    }
}

/// A hand-advanced monotonic clock, so a test controls the uptime a connection
/// measures for the reconnect counter reset.
final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now

    var current: ContinuousClock.Instant {
        lock.withLock { instant }
    }

    func advance(by duration: Duration) {
        lock.withLock { instant = instant.advanced(by: duration) }
    }
}

/// A seedable generator so a reconnect schedule reproduces exactly in tests
/// (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

// MARK: - Config presets

/// A config whose timers are all far in the future, so no watchdog, auth, or
/// query timer fires during a fast test unless the test opts into a short one.
func inertConfig(policy: ReconnectPolicy = .default) -> RelayConnectionConfig {
    RelayConnectionConfig(
        reconnectPolicy: policy,
        backgroundGrace: .seconds(3600),
        pingInterval: .seconds(3600),
        pingDeadline: .seconds(3600),
        idleTimeout: .seconds(3600),
        handshakeTimeout: .seconds(3600),
        foregroundHandshakeDeadline: .seconds(3600),
        authTimeout: .seconds(3600),
        queryTimeout: .seconds(3600),
        publishTimeout: .seconds(3600)
    )
}

// MARK: - Connection factory

let testRelayURL = URL(string: "wss://relay.example.com")!

/// A connection wired for a fast, deterministic test: instant backoff and a
/// config whose timers never fire on their own.
func makeInertConnection(
    signer: some EventSigner,
    transports: TransportQueue,
    config: RelayConnectionConfig = inertConfig(),
    backoffSleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }
) -> RelayConnection {
    RelayConnection(
        url: testRelayURL,
        signer: signer,
        config: config,
        makeTransport: { await transports.next() },
        backoffSleep: backoffSleep
    )
}

// MARK: - Frame builders

/// Raw relay-to-client frames, matching the wire shapes ``RelayMessage`` decodes.
enum Frames {
    static func challenge(_ token: String) -> String {
        #"["AUTH","\#(token)"]"#
    }

    static func ok(_ eventID: String, _ accepted: Bool, _ message: String = "") -> String {
        #"["OK","\#(eventID)",\#(accepted ? "true" : "false"),"\#(message)"]"#
    }

    /// An `OK` frame whose message is properly JSON-escaped rather than interpolated
    /// raw. A command kind's answer is itself JSON carried inside a JSON string, so
    /// its quotes must survive the nesting; ``ok(_:_:_:)`` would produce an
    /// undecodable frame.
    static func okEncoding(_ eventID: String, _ accepted: Bool, _ message: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: ["OK", eventID, accepted, message]),
              let frame = String(bytes: data, encoding: .utf8)
        else {
            return ok(eventID, accepted)
        }
        return frame
    }

    static func eose(_ subscriptionID: String) -> String {
        #"["EOSE","\#(subscriptionID)"]"#
    }

    static func closed(_ subscriptionID: String, _ message: String) -> String {
        #"["CLOSED","\#(subscriptionID)","\#(message)"]"#
    }

    static func event(_ subscriptionID: String, _ event: NostrEvent) -> String {
        // A valid event always encodes; the fallback keeps this non-throwing for
        // inline use while never being reached in practice.
        guard let data = try? JSONEncoder().encode(event),
              let json = String(bytes: data, encoding: .utf8)
        else {
            return #"["EVENT","\#(subscriptionID)",{}]"#
        }
        return #"["EVENT","\#(subscriptionID)",\#(json)]"#
    }
}

// MARK: - Frame parsing

/// The id of the auth event inside an `["AUTH", {event}]` frame the client sent.
func authEventID(from frame: String) throws -> String {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8))
    guard case let .auth(event) = message else {
        throw HarnessError.notAuthFrame(frame)
    }
    return event.id
}

/// The subscription id inside a `["REQ", id, ...]` frame the client sent.
func reqSubscriptionID(from frame: String) throws -> String {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8))
    guard case let .req(subscriptionID, _) = message else {
        throw HarnessError.notReqFrame(frame)
    }
    return subscriptionID
}

/// The event id inside an `["EVENT", ...]` frame the client sent as a publish.
func publishedEventID(from frame: String) throws -> String {
    let message = try JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8))
    guard case let .event(event) = message else {
        throw HarnessError.notEventFrame(frame)
    }
    return event.id
}

enum HarnessError: Error {
    case notAuthFrame(String)
    case notReqFrame(String)
    case notEventFrame(String)
}

// MARK: - Auth driving

/// Answers a challenge on `relay` and feeds back an accepting `OK`, then waits
/// for the connection to reach `ready`. `authSendIndex` is where the client's
/// AUTH answer lands in the relay's recorded sends.
func driveAuthToReady(
    _ connection: RelayConnection,
    _ relay: FakeRelay,
    challenge: String = "challenge-1",
    authSendIndex: Int
) async throws {
    await relay.enqueue(Frames.challenge(challenge))
    let authFrame = await relay.awaitSend(index: authSendIndex)
    let authID = try authEventID(from: authFrame)
    await relay.enqueue(Frames.ok(authID, true))
    await waitForState(connection) { $0 == .ready }
}

// MARK: - State waiting

/// Suspends until the connection reaches a state satisfying `predicate`. The
/// state feed replays the current value on subscribe, so a state reached before
/// this call is still observed.
func waitForState(
    _ connection: RelayConnection,
    _ predicate: @escaping @Sendable (ConnectionState) -> Bool
) async {
    for await state in await connection.connectionStates() where predicate(state) {
        return
    }
}

/// Spins until `condition` holds, yielding between checks. For coordinating on
/// actor-internal counters a state feed does not expose.
func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    while await !condition() {
        await Task.yield()
    }
}
