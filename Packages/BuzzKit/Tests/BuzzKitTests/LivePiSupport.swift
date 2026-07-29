@testable import BuzzKit
import Foundation
import NostrCore

/// Env-gating and wiring for the live Pi integration suite, mirroring the Phase-1
/// `RelayIntegrationTests` gate: the suite is disabled unless `BUZZKIT_INTEGRATION_URL`
/// names a relay (e.g. `wss://homelab.tail4bc643.ts.net`), so CI and ordinary local
/// runs never touch the network. The HTTP `/query` base is derived from the same host,
/// exactly as the Phase-1 suite derives it.
enum LiveRelay {
    static let urlString = ProcessInfo.processInfo.environment["BUZZKIT_INTEGRATION_URL"]
    static var enabled: Bool { urlString != nil }

    static var wsURL: URL { URL(string: urlString!)! }

    static var httpBase: URL {
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "ws" ? "http" : "https"
        return components.url!
    }

    static var queryURL: URL { httpBase.appendingPathComponent("query") }

    /// A fresh lowercase UUID-v4 channel id, matching the relay's advertised
    /// `h_grammar: uuid-v4-lowercase`.
    static func channelID() -> String { UUID().uuidString.lowercased() }
}

/// One fully-wired production ``SyncEngine`` over the real socket and HTTP transports
/// — the composition `EngineHarness` fakes, built for real against the Pi. The store is
/// passed in so a relaunch (a second engine on the same database) models a real app
/// restart, the way T3 does.
struct LiveEngine {
    let engine: SyncEngine
    let connection: RelayConnection
    let subscriptions: SubscriptionManager

    init(store: BuzzEventStore, signer: some EventSigner) {
        let connection = RelayConnection(url: LiveRelay.wsURL, signer: signer)
        self.connection = connection
        let subscriptions = SubscriptionManager(connection: connection, signer: signer)
        self.subscriptions = subscriptions
        let transport = URLSessionHTTPTransport()
        let windowClient = WindowClient(
            transport: transport, queryURL: LiveRelay.queryURL, signer: signer
        )
        let directoryClient = ChannelDirectoryClient(
            transport: transport, queryURL: LiveRelay.queryURL, signer: signer
        )
        engine = SyncEngine(
            connection: connection,
            subscriptions: subscriptions,
            store: store,
            presence: PresenceStore(),
            windowClient: windowClient,
            directoryClient: directoryClient,
            signer: signer
        )
    }
}

// MARK: - Live event builders

/// A NIP-29 create-group event (kind 9007), the SDK-shaped self-provision the live
/// suite uses: `h` = the new channel, `name`, `channel_type stream`, `visibility open`.
/// The relay authors the 39000/39001/39002 group state in response.
func createChannelEvent(
    channel: String,
    name: String,
    signer: some EventSigner,
    isPrivate: Bool = false,
    ttlSeconds: Int? = nil
) async throws -> NostrEvent {
    var tags = [
        ["h", channel],
        ["name", name],
        ["channel_type", "stream"],
        ["visibility", isPrivate ? "private" : "open"],
    ]
    if let ttlSeconds {
        tags.append(["ttl", String(ttlSeconds)])
    }
    return try await signer.sign(
        kind: .groupCreate,
        content: "",
        tags: tags
    )
}

/// A kind-9 channel message `#h`-scoped to `channel`.
func channelMessageEvent(_ content: String, channel: String, signer: some EventSigner) async throws -> NostrEvent {
    try await signer.sign(kind: .channelMessage, content: content, tags: [["h", channel]])
}

// MARK: - Bounded waits and publish

/// Polls `condition` until it holds or `timeout` elapses, returning whether it held.
/// Unlike `EngineHarness.waitUntil`, this is bounded, so the live suite reports a
/// timeout as a finding rather than hanging until the suite's overall time limit.
func poll(timeout: Duration, _ condition: @escaping @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return await condition()
}

/// Connects and waits for `.ready` (or a terminal `.stopped`), bounded by `timeout`.
func connectAndWaitReady(_ connection: RelayConnection, timeout: Duration = .seconds(30)) async -> Bool {
    do {
        try await connection.connect()
    } catch {
        return false
    }
    return await poll(timeout: timeout) { await connection.currentStateIsReady() }
}

extension RelayConnection {
    /// A one-shot ready check for the bounded poll above, off the state stream (which
    /// replays its current value on subscribe).
    func currentStateIsReady() async -> Bool {
        for await state in connectionStates() {
            return state == .ready
        }
        return false
    }
}

/// Publishes `event` on `connection`, returning `nil` on success or a human
/// description of the rejection — so the live suite records what the relay said
/// instead of failing on an unconfirmed behavior.
func tryPublish(_ event: NostrEvent, on connection: RelayConnection) async -> String? {
    do {
        try await connection.publish(event)
        return nil
    } catch {
        return "\(error)"
    }
}

/// A live test channel whose owner and connection remain alive until an
/// owner-signed delete has been attempted. Channels are private and carry a short
/// TTL as a second cleanup boundary if the process itself is killed.
struct LiveChannelFixture: Sendable {
    let channelID: String
    let connection: RelayConnection
    let signer: any EventSigner

    static func create(
        namePrefix: String,
        signer: some EventSigner
    ) async throws -> LiveChannelFixture {
        let channelID = LiveRelay.channelID()
        let connection = RelayConnection(url: LiveRelay.wsURL, signer: signer)
        guard await connectAndWaitReady(connection) else {
            throw TransportError.requestFailed("live fixture connection never reached ready")
        }
        let create = try await createChannelEvent(
            channel: channelID,
            name: "\(namePrefix)-\(channelID.prefix(8))",
            signer: signer,
            isPrivate: true,
            ttlSeconds: 300
        )
        if let rejection = await tryPublish(create, on: connection) {
            let fixture = LiveChannelFixture(
                channelID: channelID,
                connection: connection,
                signer: signer
            )
            await fixture.cleanup()
            throw TransportError.requestFailed("live fixture create rejected: \(rejection)")
        }
        return LiveChannelFixture(channelID: channelID, connection: connection, signer: signer)
    }

    func cleanup() async {
        if let event = try? await signer.sign(
            kind: .groupDelete,
            content: "",
            tags: [["h", channelID]]
        ) {
            _ = await tryPublish(event, on: connection)
        }
        await connection.stop()
    }
}

/// Runs `operation` with cleanup on success, error, and cooperative
/// cancellation. Cleanup is idempotent; the cancellation handler may race the
/// ordinary unwind and both are allowed to attempt the same owner-signed delete.
private actor LiveFixtureCleanupBox {
    private var fixture: LiveChannelFixture?

    func store(_ fixture: LiveChannelFixture) {
        self.fixture = fixture
    }

    func cleanup() async {
        guard let fixture else { return }
        self.fixture = nil
        await fixture.cleanup()
    }
}

func withLiveChannelFixture<Result: Sendable>(
    namePrefix: String,
    signer: some EventSigner,
    operation: @escaping @Sendable (LiveChannelFixture) async throws -> Result
) async throws -> Result {
    let cleanup = LiveFixtureCleanupBox()
    return try await withTaskCancellationHandler {
        let fixture = try await LiveChannelFixture.create(namePrefix: namePrefix, signer: signer)
        await cleanup.store(fixture)
        do {
            try Task.checkCancellation()
            let result = try await operation(fixture)
            await cleanup.cleanup()
            return result
        } catch {
            await cleanup.cleanup()
            throw error
        }
    } onCancel: {
        Task { await cleanup.cleanup() }
    }
}
