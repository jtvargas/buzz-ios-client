@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The per-channel typing subscription (measured relay fact: h-tagged typing is
/// fanned out only to a subscription carrying the matching `#h`, so the global
/// content filter never receives it). Opening a channel registers a dedicated
/// `kinds:[20002] + #h` REQ routed to the engine sink; a typing event on it lands
/// in ``PresenceStore`` keyed `(channel, pubkey)`; closing the channel unregisters.
@Suite("Per-channel typing subscription", .timeLimit(.minutes(1)))
struct TypingSubscriptionTests {
    @Test("opening a channel registers a typing REQ scoped kinds=[20002] + #h=[channel]")
    func opensScopedTypingREQ() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)

        try await harness.engine.openChannelTyping("room-1")
        let request = await typingREQ(on: socket, channel: "room-1")

        #expect(request.filter.kinds == [.typing])
        #expect(request.filter.tagQueries["h"] == ["room-1"])
    }

    @Test("a typing event on the channel subscription lands in PresenceStore keyed (channel, pubkey)")
    func deliversTypingToPresence() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let peer = try Fixture()

        try await bootstrap(harness, socket)
        try await harness.engine.openChannelTyping("room-1")
        let request = await typingREQ(on: socket, channel: "room-1")

        // A peer types: kind-20002 scoped to the channel by `h`. Followed by EOSE so
        // the manager flushes its backfill buffer (batch size 2) and the sink runs.
        let typing = try peer.event(.typing, "", tags: [["h", "room-1"]], at: 1_700_000_000)
        await socket.enqueue(EngineFrames.event(request.id, typing))
        await socket.enqueue(EngineFrames.eose(request.id))

        await waitUntil { await harness.presence.typingSnapshot(in: "room-1").contains(peer.pubkey) }
        // And it is channel-scoped, not leaked into another channel.
        #expect(await harness.presence.typingSnapshot(in: "room-2").isEmpty)
    }

    @Test("closing a channel unregisters its typing subscription with a CLOSE")
    func closingUnregisters() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        try await harness.engine.openChannelTyping("room-1")
        let request = await typingREQ(on: socket, channel: "room-1")

        await harness.engine.closeChannelTyping("room-1")
        await waitUntil { await sentClose(on: socket, subscriptionID: request.id) }
    }

    @Test("opening the same channel twice is idempotent — one subscription")
    func openIsIdempotent() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await bootstrap(harness, socket)
        let first = try await harness.engine.openChannelTyping("room-1")
        let second = try await harness.engine.openChannelTyping("room-1")
        #expect(first == second)
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

    /// The first typing REQ (`kinds == [20002]`) on the relay, with its id and filter.
    private func typingREQ(on relay: ScriptedRelay, channel _: String) async -> (id: String, filter: Filter) {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame),
                   let filter = request.filters.first(where: { $0.kinds == [.typing] }) {
                    return (request.id, filter)
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
