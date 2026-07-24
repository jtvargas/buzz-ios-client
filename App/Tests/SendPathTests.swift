import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Send path", .timeLimit(.minutes(1)))
struct SendPathTests {
    @Test("optimistic send drives pending → sent on a scripted OK")
    func pendingToSent() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let socket = ScriptedRelay()
        let harness = try EngineHarness(path: temp.path, identity: try PrivateKey(), relays: [socket])

        let model = ChannelTimelineModel(channel: "room-1", store: harness.store, sender: harness.engine)
        let run = Task { await model.run() }
        defer { run.cancel() }

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        model.draft = "hello from the slice"
        model.send()
        #expect(model.draft.isEmpty) // cleared optimistically

        let id = await awaitAnyPublish(on: socket)
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .pending } }

        await socket.enqueue(EngineFrames.ok(id, true))
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .sent } }

        let row = try #require(model.rows.first { $0.id == id })
        #expect(row.content == "hello from the slice")
        await harness.engine.stop()
    }

    @Test("a rejected send goes pending → failed, and an explicit retry drives it to sent")
    func failedThenRetry() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let socket = ScriptedRelay()
        let harness = try EngineHarness(path: temp.path, identity: try PrivateKey(), relays: [socket])

        let model = ChannelTimelineModel(channel: "room-1", store: harness.store, sender: harness.engine)
        let run = Task { await model.run() }
        defer { run.cancel() }

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        model.draft = "will be blocked"
        model.send()

        let id = await awaitAnyPublish(on: socket)
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .pending } }
        // A terminal `blocked:` rejection marks the row failed with the reason.
        await socket.enqueue(EngineFrames.ok(id, false, "blocked: nope"))
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .failed("nope") } }

        // The failed row is not resent automatically — the explicit retry re-drains.
        model.retry(id)
        await awaitPublishCount(on: socket, eventID: id, atLeast: 2)
        await socket.enqueue(EngineFrames.ok(id, true))
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .sent } }

        await harness.engine.stop()
    }
}
