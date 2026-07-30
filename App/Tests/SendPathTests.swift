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

    @Test("a failed send goes pending → failed, and an explicit retry drives it to sent")
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
        // Complete the first publish with a retryable verdict, then put the row in
        // the retryable failed state this UI-path test starts from. Relay verdict
        // classification and attempt exhaustion are covered by BuzzKit.
        await socket.enqueue(EngineFrames.ok(id, false, "error: nope"))
        await waitUntil {
            let entry = try? await harness.store.entry(id: id)
            return entry?.state == .pending
        }
        try await harness.store.markFailed(id, error: "nope")
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .failed("nope") } }

        // The failed row is not resent automatically — the explicit retry re-drains.
        model.retry(id)
        await awaitPublishCount(on: socket, eventID: id, atLeast: 2)
        await socket.enqueue(EngineFrames.ok(id, true))
        await waitUntil { model.rows.contains { $0.id == id && $0.delivery == .sent } }

        await harness.engine.stop()
    }
}
