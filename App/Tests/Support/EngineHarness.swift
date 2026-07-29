import BuzzKit
import Foundation
import NostrCore

/// One fully-wired ``SyncEngine`` over scripted fakes on a real on-disk store —
/// composed exactly as ``AppEnvironment`` composes production, but with the socket
/// and HTTP transports scripted. Built entirely from BuzzKit / NostrCore's public
/// surface (the public `BuzzEventStore(path:)` init, no `@testable`), so it links
/// against the shipping packages the app links.
struct EngineHarness {
    let engine: SyncEngine
    let connection: RelayConnection
    let store: BuzzEventStore
    let signer: InMemorySigner
    let http: FakeHTTPTransport
    let path: String

    static let relayURL = URL(string: "wss://relay.example.com")!
    static let queryURL = URL(string: "https://relay.example.com/query")!

    init(path: String, identity: PrivateKey, relays: [ScriptedRelay]) throws {
        self.path = path
        let http = FakeHTTPTransport()
        self.http = http

        let transports = ScriptedTransportQueue(relays)
        let signer = InMemorySigner(identity)
        self.signer = signer

        let store = try BuzzEventStore(path: path)
        self.store = store

        let connection = RelayConnection(
            url: Self.relayURL,
            signer: signer,
            config: Self.inertConnectionConfig,
            makeTransport: { await transports.next() },
            backoffSleep: { _ in },
            graceSleep: { _ in }
        )
        self.connection = connection

        let subscriptions = SubscriptionManager(
            connection: connection,
            signer: signer,
            config: SubscriptionManagerConfig(batchSize: 2),
            liveFlushSleep: { _ in }
        )
        let windowClient = WindowClient(transport: http, queryURL: Self.queryURL, signer: signer)

        engine = SyncEngine(
            connection: connection,
            subscriptions: subscriptions,
            store: store,
            presence: PresenceStore(),
            windowClient: windowClient,
            signer: signer,
            config: SyncEngineConfig(presenceSweepInterval: .seconds(3600))
        )
    }

    /// A config whose timers are all far in the future, so no watchdog, auth, or
    /// query timer fires during a fast test.
    static let inertConnectionConfig = RelayConnectionConfig(
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

    func remove() {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: path + suffix)
        }
    }
}

// MARK: - Drive helpers

/// Answers a challenge on `relay` with an accepting `OK`, then waits for `ready`.
/// The client's AUTH answer is always the first frame it sends on a socket.
func driveAuth(_ connection: RelayConnection, _ relay: ScriptedRelay) async throws {
    await relay.enqueue(EngineFrames.challenge("challenge-1"))
    let authFrame = await relay.awaitSend(index: 0)
    let authID = try authEventID(from: authFrame)
    await relay.enqueue(EngineFrames.ok(authID, true))
    for await state in await connection.connectionStates() where state == .ready {
        return
    }
}

/// A REQ is the engine's channel-discovery query when it filters on kind 39000.
func isDiscoveryREQ(_ filters: [Filter]) -> Bool {
    filters.contains { $0.kinds?.contains(.groupMetadata) == true }
}

/// Finds the one-shot discovery query on `relay` and answers it with `events` then
/// EOSE, so the engine's on-ready orchestration proceeds. Empty `events` leaves the
/// store with no channels, so reconcile makes no window (HTTP) call.
func answerDiscovery(on relay: ScriptedRelay, events: [NostrEvent] = []) async {
    let id = await awaitREQ(on: relay, matching: isDiscoveryREQ)
    for event in events {
        if let data = try? JSONEncoder().encode(event), let json = String(bytes: data, encoding: .utf8) {
            await relay.enqueue(#"["EVENT","\#(id)",\#(json)]"#)
        }
    }
    await relay.enqueue(EngineFrames.eose(id))
}

/// Spins until a REQ whose filters satisfy `matching` has been sent, returning its
/// subscription id.
func awaitREQ(on relay: ScriptedRelay, matching: @escaping @Sendable ([Filter]) -> Bool) async -> String {
    while true {
        for frame in await relay.frames() {
            if let request = decodeREQ(frame), matching(request.filters) {
                return request.id
            }
        }
        await parkBriefly()
    }
}

/// Spins until the client has published any EVENT frame, returning its id. The only
/// EVENT frames in these tests are the sends under assertion (AUTH and REQ frames
/// decode to other cases), so the first one is the message just sent.
func awaitAnyPublish(on relay: ScriptedRelay) async -> String {
    while true {
        for frame in await relay.frames() {
            if let id = publishedEventID(frame) { return id }
        }
        await parkBriefly()
    }
}

/// Spins until at least `count` EVENT frames carrying `eventID` have been published
/// — used to observe a resend after a retry re-drains the same id.
func awaitPublishCount(on relay: ScriptedRelay, eventID: String, atLeast count: Int) async {
    while true {
        let seen = await relay.frames().filter { publishedEventID($0) == eventID }.count
        if seen >= count { return }
        await parkBriefly()
    }
}

/// Spins until `condition` holds, parking briefly between checks. The condition is
/// `@MainActor` so a test can read a main-actor view model directly and still
/// `await` cross-actor engine state from the same closure.
func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
    while await !condition() {
        await parkBriefly()
    }
}

/// A real suspension between poll iterations. This must be a sleep, never
/// `Task.yield()`: GRDB's `ValueObservation` delivers on `DispatchQueue.main`, and
/// a yield only re-enqueues the spinning task on the cooperative main executor —
/// it never gives the main thread back to libdispatch, so a yield-spin starves the
/// very delivery the condition is waiting to observe and the wait never ends.
///
/// Internal rather than private so a test asserting that something *does not* happen can
/// give the work that would have done it a real chance to run first.
func parkBriefly() async {
    try? await Task.sleep(for: .milliseconds(1))
}
