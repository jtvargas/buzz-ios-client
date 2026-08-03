import Foundation
@testable import NostrCore
import Testing

@Suite("SubscriptionManager: batched delivery, EOSE-gated cursors, validation")
struct SubscriptionManagerTests {
    // MARK: - Batch flush boundaries

    @Test("Backfill flushes at the batch boundary and again at EOSE, one ingest call per flush")
    func backfillFlushesInBatchesAndAtEOSE() async throws {
        let signer = try InMemorySigner()
        let manager = idleManager(signer: signer)
        let sink = RecordingSink()

        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)

        // 500 stored events, delivered frame by frame like a relay's replay.
        for index in 0 ..< 500 {
            await feedEvent(manager, id, index: index, createdAt: Int64(1000 + index))
        }
        await manager.route(.endOfStoredEvents(subscriptionID: id.rawValue))

        // 500 events become exactly two ingest calls: a full batch at 256, the
        // remaining 244 flushed by EOSE — never 500 per-event deliveries.
        #expect(await sink.batchSizes == [256, 244])
        #expect(await sink.phases == [.backfill, .backfill])
        #expect(await sink.totalEventCount == 500)
        #expect(await sink.ingestCallCount == 2)
        #expect(await sink.endOfStoredEventsCount == 1)

        await manager.shutdown()
    }

    // MARK: - Live tick + phase marking across the EOSE boundary

    @Test("Pre-EOSE events are backfill, post-EOSE events are live and flush on the tick")
    func liveEventsCoalesceOnTickAndAreMarkedLive() async throws {
        let signer = try InMemorySigner()
        let tick = Gate()
        let manager = idleManager(signer: signer, liveFlushSleep: { try await tick.wait($0) })
        let sink = RecordingSink()

        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)

        // One stored event, then the boundary: flushed as backfill, then EOSE.
        await feedEvent(manager, id, index: 0, createdAt: 1000)
        await manager.route(.endOfStoredEvents(subscriptionID: id.rawValue))
        #expect(await sink.phases == [.backfill])
        #expect(await sink.endOfStoredEventsCount == 1)

        // A live event now buffers behind the coalescing tick; nothing is
        // delivered until the tick fires.
        await feedEvent(manager, id, index: 1, createdAt: 1001)
        #expect(await sink.ingestCallCount == 1) // still just the backfill flush

        await tick.release()
        await waitUntil { await sink.ingestCallCount == 2 }
        #expect(await sink.phases == [.backfill, .live])
        #expect(await sink.batchSizes == [1, 1])

        await manager.shutdown()
    }

    // MARK: - EOSE-gated replay cursor

    @Test("A reconnect before the first EOSE re-runs the original filter, no cursor", .timeLimit(.minutes(1)))
    func reconnectBeforeFirstEOSEReplaysOriginalFilter() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)

        let firstReq = await first.awaitSend(index: 1)
        #expect(try reqSubscriptionID(from: firstReq) == id.rawValue)

        // A partial replay, then the socket drops before EOSE ever arrives.
        await first.enqueue(Frames.event(id.rawValue, makeEvent(index: 0, createdAt: 5000)))
        await first.enqueueFailure(.connectionClosed)

        try await driveAuthToReady(connection, second, authSendIndex: 0)
        let replayReq = await second.awaitSend(index: 1)
        #expect(try reqSubscriptionID(from: replayReq) == id.rawValue)
        // No EOSE was seen, so the cursor is unarmed: the original filter re-runs
        // with no `since`, re-fetching the newest-first remainder rather than
        // stepping over it.
        #expect(try requestFilters(from: replayReq).first?.since == nil)
        #expect(await sink.endOfStoredEventsCount == 0) // no EOSE was ever fabricated

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A reconnect after EOSE replays from lastSeen minus the overlap", .timeLimit(.minutes(1)))
    func reconnectAfterEOSEReplaysFromCursor() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await first.awaitSend(index: 1)

        // A complete replay: an event at 5000, then EOSE arms the cursor.
        await first.enqueue(Frames.event(id.rawValue, makeEvent(index: 0, createdAt: 5000)))
        await first.enqueue(Frames.eose(id.rawValue))
        await waitUntil { await sink.endOfStoredEventsCount == 1 }

        await first.enqueueFailure(.connectionClosed)
        try await driveAuthToReady(connection, second, authSendIndex: 0)
        let replayReq = await second.awaitSend(index: 1)
        // 5000 − 5s overlap = 4995.
        #expect(try requestFilters(from: replayReq).first?.since == 4995)

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A mid-backfill drop re-runs the original filter and re-ingests, no fabricated EOSE", .timeLimit(.minutes(1)))
    func midBackfillDropReplaysWithoutSkip() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await first.awaitSend(index: 1)

        // The newest event arrives, then the socket drops before EOSE — the hole
        // below it is exactly the data-loss case the EOSE gate protects.
        await first.enqueue(Frames.event(id.rawValue, makeEvent(index: 0, createdAt: 5000)))
        await first.enqueueFailure(.connectionClosed)

        try await driveAuthToReady(connection, second, authSendIndex: 0)
        let replayReq = await second.awaitSend(index: 1)
        #expect(try requestFilters(from: replayReq).first?.since == nil) // original filter

        // The relay re-delivers the full set on the new socket; nothing was
        // skipped, and only the real EOSE is signalled.
        await second.enqueue(Frames.event(id.rawValue, makeEvent(index: 0, createdAt: 5000)))
        await second.enqueue(Frames.event(id.rawValue, makeEvent(index: 1, createdAt: 5001)))
        await second.enqueue(Frames.eose(id.rawValue))
        await waitUntil { await sink.endOfStoredEventsCount == 1 }

        #expect(await sink.totalEventCount == 2)
        #expect(await sink.endOfStoredEventsCount == 1)

        await manager.shutdown()
        await connection.stop()
    }

    // MARK: - Pre-send validation

    @Test("Registration rejects kindless and mis-scoped pubkey-gated filters, and accepts a valid one")
    func registrationRejectsInvalidFilters() async throws {
        let signer = try InMemorySigner()
        let myPubkey = try await signer.publicKey().hex
        let manager = idleManager(signer: signer)
        let sink = RecordingSink()

        await #expect(throws: SubscriptionError.kindlessFilter) {
            _ = try await manager.register(filters: [Filter(authors: ["abc"])], sink: sink)
        }

        // A pubkey-gated kind scoped to someone else.
        let foreign = Filter(kinds: [.giftWrap], tagQueries: ["p": [String(repeating: "b", count: 64)]])
        await #expect(throws: SubscriptionError.pubkeyScopeRequired(.giftWrap)) {
            _ = try await manager.register(filters: [foreign], sink: sink)
        }

        // A pubkey-gated kind with no `#p` scope at all.
        await #expect(throws: SubscriptionError.pubkeyScopeRequired(.memberAdded)) {
            _ = try await manager.register(filters: [Filter(kinds: [.memberAdded])], sink: sink)
        }

        // Correctly scoped to the authenticated identity: accepted.
        let correct = Filter(kinds: [.giftWrap], tagQueries: ["p": [myPubkey]])
        let id = try await manager.register(filters: [correct], sink: sink)
        #expect(id.rawValue.hasPrefix("s"))

        await manager.shutdown()
    }

    // MARK: - Re-arm on reconnect

    @Test("A live subscription is re-REQed automatically when the connection returns to ready", .timeLimit(.minutes(1)))
    func liveSubscriptionReArmsOnReconnect() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await first.awaitSend(index: 1) // initial REQ on the first socket

        await first.enqueueFailure(.connectionClosed)
        try await driveAuthToReady(connection, second, authSendIndex: 0)

        let reArmed = await second.awaitSend(index: 1)
        #expect(try reqSubscriptionID(from: reArmed) == id.rawValue)

        await manager.shutdown()
        await connection.stop()
    }

    @Test("The prioritised subscription is re-REQed before the others on reconnect", .timeLimit(.minutes(1)))
    func prioritisedSubscriptionReArmsFirst() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)

        // Three subscriptions, so the assertion cannot pass on a coin flip: only one of
        // the six possible orders puts the *last* registered one first.
        var ids: [SubscriptionID] = []
        for kind in [EventKind.channelMessage, .richMessage, .reaction] {
            ids.append(try await manager.register(filters: [Filter(kinds: [kind])], sink: RecordingSink()))
            _ = await first.awaitSend(index: ids.count) // initial REQ on the first socket
        }
        let last = try #require(ids.last)
        await manager.prioritise(last)

        await first.enqueueFailure(.connectionClosed)
        try await driveAuthToReady(connection, second, authSendIndex: 0)

        let firstReArmed = await second.awaitSend(index: 1)
        #expect(try reqSubscriptionID(from: firstReArmed) == last.rawValue)

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A priority naming a subscription that is gone leaves re-arming intact", .timeLimit(.minutes(1)))
    func stalePriorityDoesNotStrandReArming() async throws {
        let signer = try InMemorySigner()
        let first = FakeRelay()
        let second = FakeRelay()
        let transports = TransportQueue([first, second])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)

        try await connection.connect()
        try await driveAuthToReady(connection, first, authSendIndex: 0)
        let survivor = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: RecordingSink())
        _ = await first.awaitSend(index: 1)
        let doomed = try await manager.register(filters: [Filter(kinds: [.richMessage])], sink: RecordingSink())
        _ = await first.awaitSend(index: 2)

        // Prioritise, then unsubscribe the very subscription named. The stale id must be
        // skipped rather than consume the first slot or abort the walk.
        await manager.prioritise(doomed)
        await manager.unsubscribe(doomed)
        _ = await first.awaitSend(index: 3) // CLOSE

        await first.enqueueFailure(.connectionClosed)
        try await driveAuthToReady(connection, second, authSendIndex: 0)

        let reArmed = await second.awaitSend(index: 1)
        #expect(try reqSubscriptionID(from: reArmed) == survivor.rawValue)

        await manager.shutdown()
        await connection.stop()
    }

    // MARK: - Unsubscribe

    @Test("Unsubscribe sends CLOSE and drops later frames for the dead subscription", .timeLimit(.minutes(1)))
    func unsubscribeSendsCloseAndDropsLateFrames() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await relay.awaitSend(index: 1) // REQ

        await manager.unsubscribe(id)
        let closeFrame = await relay.awaitSend(index: 2)
        #expect(try closeSubscriptionID(from: closeFrame) == id.rawValue)

        // A straggler the relay sent before it processed the CLOSE is dropped.
        await feedEvent(manager, id, index: 0, createdAt: 1)
        #expect(await sink.ingestCallCount == 0)

        await manager.shutdown()
        await connection.stop()
    }

    // MARK: - CLOSED handling

    @Test("A CLOSED restricted routes the classified reason to the sink's error surface", .timeLimit(.minutes(1)))
    func closedRestrictedRoutesToErrorSurface() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await relay.awaitSend(index: 1)

        await relay.enqueue(Frames.closed(id.rawValue, "restricted: not a member"))
        await waitUntil { await sink.closureCount == 1 }

        let closure = await sink.closureAt(0)
        #expect(closure.subscription == id)
        #expect(closure.error == .closedByRelay(.restricted("not a member")))

        // The subscription is gone: no re-REQ was attempted (only AUTH + REQ).
        #expect(await relay.sentFrames.count == 2)

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A rate-limited CLOSED re-REQs the subscription instead of surfacing it", .timeLimit(.minutes(1)))
    func rateLimitedCloseRetriesRatherThanSurfacing() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)
        // No real waiting: the backoff and the gate both resolve immediately, so the test asserts
        // *that* the retry happens rather than how long it slept.
        let manager = SubscriptionManager(
            connection: connection,
            signer: signer,
            rateLimitGate: RelayRateLimitGate(sleepFor: { _ in }),
            pacingSleep: { _ in },
            jitter: { 0 }
        )
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await relay.awaitSend(index: 1) // the first REQ

        await relay.enqueue(Frames.closed(id.rawValue, "rate-limited: slow down, retry in 1s"))

        // The proof: a second REQ for the same subscription id, and nothing on the error surface.
        // Bounded rather than `awaitSend`, so dropping the subscription again fails this in a
        // second instead of hanging — without the retry there is no third frame, ever.
        #expect(await holds { await relay.sentFrames.count >= 3 })
        let retried = await relay.sentFrames[2]
        #expect(try reqSubscriptionID(from: retried) == id.rawValue)
        #expect(await sink.closureCount == 0)

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A subscription refused past its retry budget finally surfaces", .timeLimit(.minutes(1)))
    func rateLimitedCloseSurfacesOnceRetriesAreSpent() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(
            connection: connection,
            signer: signer,
            config: SubscriptionManagerConfig(maxClosedRetries: 2),
            rateLimitGate: RelayRateLimitGate(sleepFor: { _ in }),
            pacingSleep: { _ in },
            jitter: { 0 }
        )
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await relay.awaitSend(index: 1)

        // Refuse every re-REQ. The budget is two, so the third refusal is the one that gives up
        // and hands the channel to the engine's own recovery.
        for attempt in 0 ..< 3 {
            await relay.enqueue(Frames.closed(id.rawValue, "rate-limited: still busy"))
            if attempt < 2 {
                #expect(await holds { await relay.sentFrames.count >= 3 + attempt })
            }
        }
        #expect(await holds { await sink.closureCount == 1 })

        let closure = await sink.closureAt(0)
        #expect(closure.subscription == id)
        #expect(closure.error == .closedByRelay(.rateLimited("still busy")))

        await manager.shutdown()
        await connection.stop()
    }

    @Test("A CLOSED auth-required re-REQs once, then surfaces on a second", .timeLimit(.minutes(1)))
    func closedAuthRequiredReRequestsOnceThenSurfaces() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)
        let manager = SubscriptionManager(connection: connection, signer: signer)
        let sink = RecordingSink()

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)
        let id = try await manager.register(filters: [Filter(kinds: [.channelMessage])], sink: sink)
        _ = await relay.awaitSend(index: 1)

        // First auth-required close: the manager re-opens the subscription once,
        // mirroring the connection's one-shot retry-once discipline.
        await relay.enqueue(Frames.closed(id.rawValue, "auth-required: re-authenticate"))
        let retriedReq = await relay.awaitSend(index: 2)
        #expect(try reqSubscriptionID(from: retriedReq) == id.rawValue)

        // A second auth-required close exhausts the single retry: it surfaces.
        await relay.enqueue(Frames.closed(id.rawValue, "auth-required: again"))
        await waitUntil { await sink.closureCount == 1 }
        #expect(await sink.closureAt(0).error == .closedByRelay(.authRequired("again")))

        await manager.shutdown()
        await connection.stop()
    }
}
