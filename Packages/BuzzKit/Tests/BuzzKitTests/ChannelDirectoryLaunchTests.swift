@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

@Suite("Authoritative channel directory launch", .serialized)
struct ChannelDirectoryLaunchTests {
    @Test("a signed channel list fails closed even when the access seed marker is absent")
    func signedListFailsClosedWithoutSeedMarker() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let identity = try Fixture()

        try await store.ingest(batch: [
            relay.event(.groupMetadata, #"{"name":"Deleted"}"#, tags: [["d", "deleted"]]),
            relay.event(.groupMetadata, #"{"name":"Left"}"#, tags: [["d", "left"]]),
        ], phase: .backfill)
        try await store.markChannelAccess(
            identity: identity.pubkey,
            channel: "deleted",
            state: .deleted
        )
        try await store.markChannelAccess(
            identity: identity.pubkey,
            channel: "left",
            state: .notMember
        )

        #expect(try await store.metaValue("channel_access_seeded:\(identity.pubkey)") == nil)
        #expect(try store.channelList(selfPubkey: identity.pubkey).isEmpty)
    }

    @Test("an accepted delete survives close, projection rebuild, and another seed")
    func deletedAccessSurvivesReopenAndReseed() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let relay = try Fixture()
        let identity = try PrivateKey()
        let selfPubkey = identity.publicKey.hex

        do {
            let socket = ScriptedRelay()
            let harness = try EngineHarness(
                path: database.path,
                identity: identity,
                relays: [socket]
            )
            try await harness.engine.start()
            try await driveAuth(harness.connection, socket)
            await answerDiscovery(on: socket)
            await waitUntil { await harness.engine.state == .running }

            try await harness.store.ingest(batch: [
                relay.event(.groupMetadata, #"{"name":"Gone"}"#, tags: [["d", "room"]], at: 10),
                relay.event(
                    .groupMembers,
                    "",
                    tags: [["d", "room"], ["p", selfPubkey]],
                    at: 11
                ),
            ], phase: .backfill)
            try await harness.store.seedChannelAccessIfNeeded(identity: selfPubkey)

            let deletion = Task { try await harness.engine.deleteChannel(id: "room") }
            let command = await awaitPublishedEvent(on: socket)
            #expect(command.kind == .groupDelete)
            #expect(command.tags == [["h", "room"]])
            await socket.enqueue(EngineFrames.ok(command.id, true))
            try await deletion.value
            #expect(
                try harness.store.channelAccessState(identity: selfPubkey, channel: "room")
                    == .deleted
            )

            try await harness.store.writer.write { db in
                try db.execute(
                    sql: "DELETE FROM meta WHERE key = ?",
                    arguments: ["channel_access_seeded:\(selfPubkey)"]
                )
            }
            await harness.engine.stop()
        }

        let reopened = try database.open(projectionVersion: Schema.projectionVersion + 1)
        try await reopened.seedChannelAccessIfNeeded(identity: selfPubkey)
        try await reopened.markChannelAccess(
            identity: selfPubkey,
            channel: "room",
            state: .active
        )
        try await reopened.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [], states: ["room": .active]),
            identity: selfPubkey
        )

        #expect(try reopened.channelAccessState(identity: selfPubkey, channel: "room") == .deleted)
        #expect(try reopened.channelList(selfPubkey: selfPubkey).isEmpty)
    }

    @Test("cold launch waits for directory reconciliation before its first visible list")
    func coldLaunchWaitsForDirectory() async throws {
        let socket = ScriptedRelay()
        let directory = ControlledChannelDirectory()
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()
        let harness = try EngineHarness(
            path: database.path,
            identity: identity,
            relays: [socket],
            directoryClient: TestChannelDirectoryClient(directory)
        )
        let relay = try Fixture()
        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, #"{"name":"Gone"}"#, tags: [["d", "room"]], at: 10),
            relay.event(
                .groupMembers,
                "",
                tags: [["d", "room"], ["p", harness.selfPubkey]],
                at: 11
            ),
        ], phase: .backfill)

        let completion = CompletionProbe()
        let start = Task {
            try await harness.engine.start()
            await completion.finish()
        }
        await waitUntil { await directory.requestCount == 1 }
        #expect(await completion.isFinished == false)

        await directory.succeedNext(
            ChannelDirectorySnapshot(events: [], states: ["room": .notMember])
        )
        try await start.value

        #expect(await completion.isFinished)
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).isEmpty)
        await harness.engine.stop()
    }

    @Test("directory failure mounts the cached list and reports a retryable fallback")
    func directoryFailurePreservesCache() async throws {
        let socket = ScriptedRelay()
        let directory = ControlledChannelDirectory()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            directoryClient: TestChannelDirectoryClient(directory)
        )
        let relay = try Fixture()
        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, #"{"name":"Saved"}"#, tags: [["d", "room"]], at: 10),
            relay.event(
                .groupMembers,
                "",
                tags: [["d", "room"], ["p", harness.selfPubkey]],
                at: 11
            ),
        ], phase: .backfill)

        let statuses = await harness.engine.channelDirectoryStatuses()
        var iterator = statuses.makeAsyncIterator()
        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        await directory.failNext()
        try await start.value

        #expect(await iterator.next() == .checking)
        #expect(await iterator.next() == .cachedFallback)
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).map(\.id) == ["room"])
        await harness.engine.stop()
    }

    @Test("initial socket failure reconnects and Retry drives socket plus directory recovery")
    func initialConnectionFailureAndRetryRecover() async throws {
        let first = ScriptedRelay()
        await first.failConnect(with: .connectFailed("offline"))
        let second = ScriptedRelay()
        let directory = ControlledChannelDirectory()
        let backoff = ControlledBackoff()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [first, second],
            directoryClient: TestChannelDirectoryClient(directory),
            backoffSleep: { _ in try await backoff.sleep() }
        )

        let start = Task { try await harness.engine.start() }
        await Task.yield()
        try #require(await waitFor { await directory.requestCount == 1 })
        await directory.failNext()
        try await start.value
        let enteredBackoff = await waitFor {
            let isSleeping = await backoff.requestCount == 1
            if case .backingOff = await harness.connection.state { return isSleeping }
            return false
        }
        let stateAfterInitialFailure = await harness.connection.state
        let backoffRequestCount = await backoff.requestCount
        try #require(
            enteredBackoff,
            "state: \(stateAfterInitialFailure), backoff requests: \(backoffRequestCount)"
        )
        #expect(await harness.transports.vendedCount == 1)

        let retry = Task { await harness.engine.retryConnectionAndDirectory() }
        try #require(await waitFor { await directory.requestCount == 2 })
        await directory.succeedNext(ChannelDirectorySnapshot(events: [], states: [:]))
        await retry.value
        try #require(await waitFor { await harness.transports.vendedCount == 2 })

        #expect(await directory.requestCount == 2)
        #expect(await harness.transports.vendedCount == 2)
        await harness.engine.stop()
    }

    @Test("overlapping directory triggers run one fetch and one coalesced follow-up")
    func directoryCoordinatorCoalescesTriggers() async throws {
        let socket = ScriptedRelay()
        let directory = ControlledChannelDirectory()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            directoryClient: TestChannelDirectoryClient(directory)
        )
        let relay = try Fixture()

        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        let pullRefresh = Task { await harness.engine.refresh() }
        await harness.engine.enterForeground()
        let membership = try relay.event(
            .memberAdded,
            "",
            tags: [["h", "room"], ["p", harness.selfPubkey]]
        )
        await harness.engine.ingest(
            batch: [membership],
            subscription: SubscriptionID("global"),
            phase: .live
        )
        if let channelSubscription = await harness.engine.channelContentSubscriptions["room"] {
            await harness.engine.subscriptionClosed(
                subscription: channelSubscription,
                error: .closedByRelay(.restricted("test"))
            )
        }
        for _ in 0 ..< 8 {
            await harness.engine.requestDirectoryRefresh()
        }
        #expect(await directory.maximumConcurrentRequests == 1)

        await directory.succeedNext(ChannelDirectorySnapshot(events: [], states: [:]))
        try await start.value
        await waitUntil { await directory.requestCount == 2 }
        #expect(await directory.maximumConcurrentRequests == 1)

        await directory.succeedNext(ChannelDirectorySnapshot(events: [], states: [:]))
        await waitUntil { await harness.engine.directoryRefreshInFlight == false }
        await pullRefresh.value

        #expect(await directory.requestCount == 2)
        #expect(await directory.maximumConcurrentRequests == 1)
        await harness.engine.stop()
    }
}

private enum ControlledDirectoryError: Error {
    case failed
}

private actor ControlledChannelDirectory: ChannelDirectoryFetching {
    private var continuations: [CheckedContinuation<ChannelDirectorySnapshot, any Error>] = []
    private var activeRequests = 0
    private(set) var requestCount = 0
    private(set) var maximumConcurrentRequests = 0

    func fetch(
        selfPubkey _: String,
        previouslyActiveChannels _: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        requestCount += 1
        activeRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, activeRequests)
        defer { activeRequests -= 1 }
        return try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func succeedNext(_ snapshot: ChannelDirectorySnapshot) {
        continuations.removeFirst().resume(returning: snapshot)
    }

    func failNext() {
        continuations.removeFirst().resume(throwing: ControlledDirectoryError.failed)
    }
}

private actor CompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

private actor ControlledBackoff {
    private var waiter: CheckedContinuation<Void, any Error>?
    private(set) var requestCount = 0

    func sleep() async throws {
        requestCount += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
    }

    private func cancelSleep() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private func waitFor(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return false
}
