@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport

/// A config whose timers are all far in the future, so no watchdog, auth, or query
/// timer fires during a fast engine test.
func inertEngineConfig() -> RelayConnectionConfig {
    RelayConnectionConfig(
        backgroundGrace: .seconds(3600),
        pingInterval: .seconds(3600),
        pingDeadline: .seconds(3600),
        idleTimeout: .seconds(3600),
        authTimeout: .seconds(3600),
        queryTimeout: .seconds(3600),
        publishTimeout: .seconds(3600)
    )
}

/// One fully-wired ``SyncEngine`` over scripted fakes on a real on-disk store — the
/// exact shape the exit-criteria suites drive. A restart ("kill the app") is a
/// second harness opened on the same `path` with the same `identity` and fresh
/// fakes.
struct EngineHarness {
    let engine: SyncEngine
    let connection: RelayConnection
    let subscriptions: SubscriptionManager
    let store: BuzzEventStore
    let presence: PresenceStore
    let http: FakeHTTPTransport
    let transports: ScriptedTransportQueue
    let signer: InMemorySigner
    let selfPubkey: String

    let path: String
    let identity: PrivateKey
    let nowSeconds: Int64
    let batchSize: Int
    /// The store's injected clock, carried so a restart (``reopen(relays:)``) reopens
    /// the same database on the same clock instance — the T4 engine path, where a
    /// send's local age is what trips the relay's ±15-minute ingest gate, needs a
    /// clock the test can wind rather than the wall clock.
    let storeClock: @Sendable () -> Date

    static let relayURL = URL(string: "wss://relay.example.com")!
    static let queryURL = URL(string: "https://relay.example.com/query")!

    init(
        path: String,
        identity: PrivateKey,
        relays: [ScriptedRelay],
        http: FakeHTTPTransport = FakeHTTPTransport(),
        nowSeconds: Int64 = 1_700_000_000,
        batchSize: Int = 2,
        storeClock: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.path = path
        self.identity = identity
        self.http = http
        self.nowSeconds = nowSeconds
        self.batchSize = batchSize
        self.storeClock = storeClock

        let transports = ScriptedTransportQueue(relays)
        self.transports = transports
        let signer = InMemorySigner(identity)
        self.signer = signer
        selfPubkey = identity.publicKey.hex

        // The production projector, as `BuzzEventStore(path:)` wires — discovery and
        // reconcile ingest through it — but with an injectable clock for the age-based
        // outbox re-sign.
        let store = try BuzzEventStore(path: path, projector: BuzzProjector(), clock: storeClock)
        self.store = store
        let presence = PresenceStore()
        self.presence = presence

        let connection = RelayConnection(
            url: Self.relayURL,
            signer: signer,
            config: inertEngineConfig(),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in },
            graceSleep: { _ in }
        )
        self.connection = connection

        let subscriptions = SubscriptionManager(
            connection: connection,
            signer: signer,
            config: SubscriptionManagerConfig(batchSize: batchSize),
            liveFlushSleep: { _ in }
        )
        self.subscriptions = subscriptions

        let windowClient = WindowClient(transport: http, queryURL: Self.queryURL, signer: signer)

        let seconds = nowSeconds
        engine = SyncEngine(
            connection: connection,
            subscriptions: subscriptions,
            store: store,
            presence: presence,
            windowClient: windowClient,
            signer: signer,
            config: SyncEngineConfig(presenceSweepInterval: .seconds(3600)),
            now: { Date(timeIntervalSince1970: TimeInterval(seconds)) }
        )
    }

    /// Reopens the same database with the same identity and fresh fakes — the
    /// engine-level meaning of "kill the app".
    func reopen(relays: [ScriptedRelay]) throws -> EngineHarness {
        try EngineHarness(
            path: path,
            identity: identity,
            relays: relays,
            http: FakeHTTPTransport(),
            nowSeconds: nowSeconds,
            batchSize: batchSize,
            storeClock: storeClock
        )
    }

    func remove() {
        let manager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? manager.removeItem(atPath: path + suffix)
        }
    }
}

// MARK: - Signed events for scripts

/// Builds signed channel messages and relay-signed group state for the engine
/// scripts — a peer authors the messages, a "relay" authors the addressable group
/// state, each with a stable key so ids are reproducible across a restart.
struct EngineFixtures {
    let peer: Fixture
    let relay: Fixture

    init() throws {
        peer = try Fixture()
        relay = try Fixture()
    }

    func message(_ content: String, in channel: String, at seconds: Int64) throws -> NostrEvent {
        try peer.event(.channelMessage, content, tags: [["h", channel]], at: seconds)
    }

    func metadata(for channel: String, name: String, at seconds: Int64 = 1_700_000_000) throws -> NostrEvent {
        try relay.event(.groupMetadata, "", tags: [["d", channel], ["name", name]], at: seconds)
    }
}

// MARK: - Filter predicates

/// The standing per-channel content REQ for `channel`: a single `#h`-scoped filter
/// carrying the channel's live kinds. Discriminated by the presence of `.typing`
/// (20002), which only the standing content sub requests — the degradation-fallback
/// history query and the window reconcile never carry typing, so this never confuses
/// them for the standing sub.
func isChannelContentREQ(_ filters: [Filter], channel: String) -> Bool {
    channelContentFilter(in: filters, channel: channel) != nil
}

func channelContentFilter(in filters: [Filter], channel: String) -> Filter? {
    filters.first { $0.tagQueries["h"] == [channel] && $0.kinds?.contains(.typing) == true }
}

/// The narrowed global content filter (metadata + presence, `#h`-less).
func globalContentFilter(in filters: [Filter]) -> Filter? {
    filters.first { $0.kinds?.contains(.metadata) == true && $0.tagQueries["h"] == nil }
}

/// The membership filter (`#p`-scoped 44100/44101 notifications).
func membershipFilter(in filters: [Filter]) -> Filter? {
    filters.first { $0.kinds?.contains(.memberAdded) == true }
}

func isDiscoveryREQ(_ filters: [Filter]) -> Bool {
    filters.contains { $0.kinds?.contains(.groupMetadata) == true }
}

/// The degradation-fallback history query: a single-kind `[.channelMessage]` filter
/// scoped by `#h`, distinct from the multi-kind standing content sub.
func isChannelHistoryREQ(_ filters: [Filter], channel: String) -> Bool {
    filters.contains { $0.kinds == [.channelMessage] && $0.tagQueries["h"] == [channel] }
}

// MARK: - Drive helpers

/// Answers a challenge on `relay` with an accepting `OK`, then waits for the
/// connection to reach `ready`. The client's AUTH answer is always the first frame
/// it sends on a socket.
func driveAuth(
    _ connection: RelayConnection,
    _ relay: ScriptedRelay,
    challenge: String = "challenge-1"
) async throws {
    await relay.enqueue(EngineFrames.challenge(challenge))
    let authFrame = await relay.awaitSend(index: 0)
    let authID = try authEventID(from: authFrame)
    await relay.enqueue(EngineFrames.ok(authID, true))
    await waitForConnectionReady(connection)
}

func waitForConnectionReady(_ connection: RelayConnection) async {
    for await state in await connection.connectionStates() where state == .ready {
        return
    }
}

/// Spins until a REQ whose filters satisfy `matching` has been sent on `relay`,
/// returning its subscription id.
func awaitREQ(
    on relay: ScriptedRelay,
    matching: @escaping @Sendable ([Filter]) -> Bool
) async -> String {
    while true {
        for frame in await relay.frames() {
            if let request = decodeREQ(frame), matching(request.filters) {
                return request.id
            }
        }
        await Task.yield()
    }
}

/// Spins until the standing content REQ for `channel` has been sent on `relay`,
/// returning its subscription id.
func awaitChannelContentREQ(on relay: ScriptedRelay, channel: String) async -> String {
    await awaitREQ(on: relay) { isChannelContentREQ($0, channel: channel) }
}

/// Spins until the standing content REQ for `channel` has been sent, returning its
/// filter — the one whose `since` a replay assertion inspects.
func awaitChannelContentFilter(on relay: ScriptedRelay, channel: String) async -> Filter {
    while true {
        for frame in await relay.frames() {
            if let request = decodeREQ(frame),
               let filter = channelContentFilter(in: request.filters, channel: channel) {
                return filter
            }
        }
        await Task.yield()
    }
}

/// Finds the one-shot discovery query on `relay` and answers it with `events`
/// followed by EOSE, so the engine's on-ready orchestration proceeds.
func answerDiscovery(on relay: ScriptedRelay, events: [NostrEvent] = []) async {
    let id = await awaitREQ(on: relay, matching: isDiscoveryREQ)
    for event in events { await relay.enqueue(EngineFrames.event(id, event)) }
    await relay.enqueue(EngineFrames.eose(id))
}

/// Spins until the client has published an EVENT frame carrying `eventID`.
func awaitPublish(on relay: ScriptedRelay, eventID: String) async {
    while true {
        for frame in await relay.frames() where publishedEventID(frame) == eventID {
            return
        }
        await Task.yield()
    }
}

/// Spins until the client has published an EVENT frame whose id is *not* `excluded`,
/// returning that id — the re-signed resend in the T4 engine path, whose fresh id
/// the test cannot predict but must answer with an `OK`.
func awaitPublish(on relay: ScriptedRelay, excluding excluded: String) async -> String {
    while true {
        for frame in await relay.frames() {
            if let id = publishedEventID(frame), id != excluded { return id }
        }
        await Task.yield()
    }
}

/// Spins until the client has published an EVENT whose id is not already in `seen`,
/// returning the whole event. A retry path that re-signs cannot have its next id
/// predicted, and an assertion on a command's tags needs more than the id.
func awaitPublishedEvent(on relay: ScriptedRelay, excluding seen: Set<String> = []) async -> NostrEvent {
    while true {
        for frame in await relay.frames() {
            if let event = publishedEvent(frame), !seen.contains(event.id) { return event }
        }
        await Task.yield()
    }
}

/// Every event the client has published on `relay` so far, in wire order.
func publishedEvents(on relay: ScriptedRelay) async -> [NostrEvent] {
    await relay.frames().compactMap(publishedEvent)
}

/// Spins until `condition` holds, yielding between checks — for coordinating on
/// engine or store state a stream does not expose directly.
func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
    while await !condition() {
        await Task.yield()
    }
}
