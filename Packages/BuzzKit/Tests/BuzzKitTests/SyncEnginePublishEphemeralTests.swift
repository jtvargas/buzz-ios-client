@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// S-3: the ephemeral publish path signs and hands the event straight to the
/// connection, and never touches the outbox — no row, no pending send, no retry.
@Suite("SyncEngine.publishEphemeral", .timeLimit(.minutes(1)))
struct SyncEnginePublishEphemeralTests {
    @Test("an ephemeral publish reaches the relay and never touches the outbox")
    func bypassesOutbox() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pubeph-\(UUID().uuidString).sqlite").path
        let socket = ScriptedRelay()
        let harness = try EngineHarness(path: path, identity: try PrivateKey(), relays: [socket])
        defer { harness.remove() }

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        // Presence is channel-less: no `h` tag, matching the upstream builder.
        let publish = Task { await harness.engine.publishEphemeral(kind: .presence, content: "online") }
        let id = await awaitPublish(on: socket, excluding: "")

        // The whole claim: the outbox is untouched by an ephemeral send.
        #expect(try await harness.store.outboxCount() == 0)
        #expect(try await harness.store.pendingSends().isEmpty)

        // The relay answers an ephemeral EVENT with an OK like any other; letting the
        // publish resolve proves the path completes rather than hanging on a missing OK.
        await socket.enqueue(EngineFrames.ok(id, true))
        await publish.value
        #expect(try await harness.store.outboxCount() == 0)

        await harness.engine.stop()
    }

    @Test("a non-ephemeral kind is refused — nothing is signed or sent")
    func refusesNonEphemeral() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pubeph-guard-\(UUID().uuidString).sqlite").path
        let socket = ScriptedRelay()
        let harness = try EngineHarness(path: path, identity: try PrivateKey(), relays: [socket])
        defer { harness.remove() }

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        // A channel message is not ephemeral: the guard returns before signing.
        await harness.engine.publishEphemeral(kind: .channelMessage, content: "not ephemeral")

        // Give any errant publish a chance to appear, then prove none did and the
        // outbox stayed empty.
        for _ in 0 ..< 20 { await Task.yield() }
        let published = await socket.frames().compactMap(publishedEventID)
        #expect(published.isEmpty)
        #expect(try await harness.store.outboxCount() == 0)

        await harness.engine.stop()
    }
}
