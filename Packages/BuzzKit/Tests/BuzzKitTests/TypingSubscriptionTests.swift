@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The standing per-channel content subscription and its typing coverage.
///
/// Typing (kind 20002) is fanned out only to a subscription whose filter carries the
/// matching `#h` (measured against the production relay). The engine no longer opens a
/// dedicated typing REQ: the standing per-channel content sub is a single `#h`-scoped
/// filter that already carries 20002 alongside the message/overlay/reaction kinds, so
/// one subscription delivers both messages and typing. A typing event on it lands in
/// ``PresenceStore`` keyed `(channel, pubkey)` (the step-2 chain), unchanged.
///
/// The old ``SyncEngine/openChannelTyping(_:)`` / ``SyncEngine/closeChannelTyping(_:)``
/// are retained as deprecated shims over the standing sub for the app's typing seam.
@Suite("Standing per-channel content subscription (carries typing)", .timeLimit(.minutes(1)))
struct TypingSubscriptionTests {
    /// The measured live-delivering shape: a single `#h`-scoped filter carrying the
    /// channel's message/overlay/reaction/deletion kinds and typing (20002).
    private static let contentKinds: [EventKind] = [
        .channelMessage, .richMessage, .messageEdit,
        .reaction, .deletion, .groupDeleteEvent, .typing,
    ]

    @Test("the standing content sub is a single #h-scoped filter carrying exactly the live kinds")
    func contentSubShapeCarriesTyping() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room-1")
        let request = await contentREQ(on: socket, channel: "room-1")

        // Exactly one filter in the REQ — never multiplexed with a global filter, or
        // the relay would demote the whole REQ to global and starve it of channel
        // traffic.
        #expect(request.filters.count == 1)
        #expect(request.filters[0].kinds == Self.contentKinds)
        #expect(request.filters[0].tagQueries["h"] == ["room-1"])
        #expect(request.filters[0].kinds?.contains(.typing) == true)
    }

    @Test("a typing event on the content sub lands in PresenceStore keyed (channel, pubkey)")
    func deliversTypingToPresence() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let peer = try Fixture()

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room-1")
        let request = await contentREQ(on: socket, channel: "room-1")

        // A peer types: kind-20002 scoped to the channel by `h`. Followed by EOSE so
        // the manager flushes its backfill buffer (batch size 2) and the sink runs.
        let typing = try peer.event(.typing, "", tags: [["h", "room-1"]], at: 1_700_000_000)
        await socket.enqueue(EngineFrames.event(request.id, typing))
        await socket.enqueue(EngineFrames.eose(request.id))

        await waitUntil { await harness.presence.typingSnapshot(in: "room-1").contains(peer.pubkey) }
        // And it is channel-scoped, not leaked into another channel.
        #expect(await harness.presence.typingSnapshot(in: "room-2").isEmpty)
    }

    @Test("openChannelTyping is a shim over the standing content sub — idempotent, same id")
    func openTypingShimReturnsContentSub() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        let first = try await harness.engine.openChannelTyping("room-1")
        let second = try await harness.engine.openChannelTyping("room-1")
        #expect(first == second)
        // It is the same subscription the standing content path tracks.
        #expect(await harness.engine.channelContentSubscriptions["room-1"] == first)
    }

    @Test("closeChannelTyping is a no-op — the standing sub persists, no CLOSE is sent")
    func closeTypingIsNoOp() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        try await harness.engine.openChannelTyping("room-1")
        let request = await contentREQ(on: socket, channel: "room-1")

        await harness.engine.closeChannelTyping("room-1")

        // The sub is still tracked, and no CLOSE frame was ever put on the wire.
        #expect(await harness.engine.channelContentSubscriptions["room-1"]?.rawValue == request.id)
        #expect(await !sentClose(on: socket, subscriptionID: request.id))
    }

    // MARK: - Harness

    /// Starts the engine, completes the auth handshake, answers discovery with no
    /// channels (so no window reconcile is attempted), and waits until running.
    private func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// The standing content REQ for `channel` on the relay, with its id and filters.
    private func contentREQ(on relay: ScriptedRelay, channel: String) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame), isChannelContentREQ(request.filters, channel: channel) {
                    return (request.id, request.filters)
                }
            }
            await Task.yield()
        }
    }

    /// Whether a `CLOSE` for `subscriptionID` has been sent on `relay`.
    private func sentClose(on relay: ScriptedRelay, subscriptionID: String) async -> Bool {
        for frame in await relay.frames() where closeSubscriptionID(frame) == subscriptionID {
            return true
        }
        return false
    }
}

/// The subscription id of a `["CLOSE", id]` client frame, or `nil` otherwise.
private func closeSubscriptionID(_ frame: String) -> String? {
    guard case let .close(id) = try? JSONDecoder().decode(ClientMessage.self, from: Data(frame.utf8)) else {
        return nil
    }
    return id
}
