@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Regressions for the Phase-2 gate findings that live in the ``SyncEngine`` — the
/// degradation-fallback watermark contract (P2-3) and superseded-generation state
/// writes (P3-2). Both drive a fully-wired engine over scripted fakes.
@Suite("Phase-2 gate regressions (engine)", .timeLimit(.minutes(1)))
struct GateEngineRegressionTests {
    // MARK: - P2-3: degraded fallback holds the watermark

    /// A degraded reconcile assembles the head from the standard filter but leaves a
    /// possibly-open gap below it, so the channel is `.fallbackSynced` and a live
    /// flush must NOT advance the watermark. A later session that reconciles through
    /// the window path closes the gap and advances the watermark normally.
    @Test("a degraded fallback holds the watermark; a later window reconcile advances it")
    func degradedFallbackHoldsWatermark() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()
        let fixtures = try EngineFixtures()

        // --- Session 1: the window path degrades, the channel falls back. ---
        let socket1 = ScriptedRelay()
        let harness1 = try EngineHarness(
            path: database.path, identity: identity, relays: [socket1], batchSize: 1
        )
        // The window fetch answers 503 → `.degraded` → fallback assembly.
        await harness1.http.enqueue(status: 503, body: Data())

        try await harness1.engine.start()
        try await driveAuth(harness1.connection, socket1)
        await answerDiscovery(on: socket1, events: [try fixtures.metadata(for: "room", name: "Room")])

        // The fallback reissues the clean standard filter over the socket; answer it
        // empty, so onReady proceeds and the channel lands `.fallbackSynced`.
        let historyID = await awaitREQ(on: socket1) { isChannelHistoryREQ($0, channel: "room") }
        await socket1.enqueue(EngineFrames.eose(historyID))
        await waitUntil { await harness1.engine.channelSyncState("room") == .fallbackSynced }

        // A live message arrives on the caught-up-but-gapped channel — on the standing
        // per-channel content sub (registered by discovery), the only live path now.
        let liveSub = await awaitChannelContentREQ(on: socket1, channel: "room")
        await socket1.enqueue(EngineFrames.eose(liveSub))
        let live = try fixtures.message("live", in: "room", at: harness1.nowSeconds + 100)
        await socket1.enqueue(EngineFrames.event(liveSub, live))
        await waitUntil { (try? await harness1.store.event(id: live.id)) != nil }

        // The watermark did not advance — the gap below the fallback is still open.
        #expect(try await harness1.store.channelWatermark("room") == nil)
        await harness1.engine.stop()

        // --- Session 2: a healthy window reconcile advances the watermark. ---
        let socket2 = ScriptedRelay()
        let harness2 = try harness1.reopen(relays: [socket2])
        let build = try WindowResponseBuilder(channel: "room")
        let head = try build.row("recovered", at: 1_700_000_010)
        let page = try WindowResponseBuilder.body([head, try build.headBounds(hasMore: false)])
        await harness2.http.enqueue(status: 200, body: page)

        try await harness2.engine.start()
        try await driveAuth(harness2.connection, socket2)
        await answerDiscovery(on: socket2, events: [try fixtures.metadata(for: "room", name: "Room")])
        await waitUntil { await harness2.engine.channelSyncState("room") == .synced }

        #expect(try await harness2.store.channelWatermark("room")
            == WindowCursor(createdAt: head.createdAt, id: head.id))
        await harness2.engine.stop()
    }

    // MARK: - P3-2: a superseded reconcile writes no channel state

    /// A reconcile from a superseded generation that returns late must abandon
    /// silently: it may not clobber the state the current generation has since
    /// reached. The gated transport lets generation 2 complete to `.synced` first,
    /// then releases generation 1's stale fetch and asserts nothing regressed.
    @Test("a late reconcile from a superseded generation does not clobber synced state")
    func staleReconcileDoesNotClobber() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()
        let socket1 = ScriptedRelay()
        let socket2 = ScriptedRelay()
        let gated = IndexedHTTPTransport()
        let rig = try makeGatedEngine(
            path: database.path, identity: identity, relays: [socket1, socket2], transport: gated
        )

        let build = try WindowResponseBuilder(channel: "room")
        let head = try build.row("head", at: 1_700_000_010)
        let page = try WindowResponseBuilder.body([head, try build.headBounds(hasMore: false)])
        let headCursor = WindowCursor(createdAt: head.createdAt, id: head.id)
        let meta = try build.relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])

        // Generation 1: reconcile "room" parks on the first window fetch (index 0).
        try await rig.engine.start()
        try await driveAuth(rig.connection, socket1)
        await answerDiscovery(on: socket1, events: [meta])
        await waitUntil { await gated.requestCount >= 1 }

        // Reconnect → generation 2; its reconcile parks on the second fetch (index 1).
        await socket1.enqueueFailure(.connectionClosed)
        try await driveAuth(rig.connection, socket2)
        await answerDiscovery(on: socket2, events: [meta])
        await waitUntil { await gated.requestCount >= 2 }

        // Complete generation 2 first: it reaches `.synced` and advances the watermark.
        await gated.respond(index: 1, status: 200, body: page)
        await waitUntil { await rig.engine.channelSyncState("room") == .synced }
        #expect(try await rig.store.channelWatermark("room") == headCursor)

        // Release the stale generation-1 fetch last. Its `guard isCurrent` fails and
        // it must return without a write — leaving G2's `.synced` and watermark.
        await gated.respond(index: 0, status: 200, body: page)
        await waitUntil { await gated.delivered(0) }
        for _ in 0 ..< 50 { await Task.yield() }

        #expect(await rig.engine.channelSyncState("room") == .synced)
        #expect(try await rig.store.channelWatermark("room") == headCursor)
        await rig.engine.stop()
    }

    // MARK: - Rule 4 under live per-channel traffic

    /// Live channel traffic now arrives on the standing per-channel content subs — a
    /// path that, before this fix, never delivered a single live event (the engine's
    /// only live REQ was `#h`-less and global, so channel events never fanned to it).
    /// Activating that path re-arms rule 4, so pin the contract directly: within one
    /// session a `.synced` channel and a `.fallbackSynced` channel receive a live
    /// kind-9 each, and the live flush must advance the synced channel's watermark
    /// (past the head the reconcile set) while holding the fallback channel's (its gap
    /// is still open).
    ///
    /// The two states coexist realistically: the window path degrades per session, so
    /// a channel reconciled *before* the degradation reaches `.synced` and one
    /// reconciled after falls back. `chan-a` sorts first and reconciles cleanly;
    /// `chan-b` reconciles next, degrades, and falls back.
    @Test("live rows advance a synced channel's watermark and hold a fallbackSynced one's")
    func liveWatermarkRule4AcrossSyncedAndFallback() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let fixtures = try EngineFixtures()

        let buildA = try WindowResponseBuilder(channel: "chan-a")
        let metaA = try buildA.relay.event(.groupMetadata, "", tags: [["d", "chan-a"], ["name", "A"]])
        let metaB = try fixtures.metadata(for: "chan-b", name: "B")
        let headRow = try buildA.row("head", at: harness.nowSeconds + 10)
        let headPage = try WindowResponseBuilder.body([headRow, try buildA.headBounds(hasMore: false)])

        // Reconcile order is sorted [chan-a, chan-b]; HTTP is FIFO: a clean head page
        // for chan-a (→ synced), a 503 for chan-b (→ degraded → fallback).
        await harness.http.enqueue(status: 200, body: headPage)
        await harness.http.enqueue(status: 503, body: Data())

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket, events: [metaA, metaB])

        // chan-b's fallback reissues the standard history query over the socket.
        let historyB = await awaitREQ(on: socket) { isChannelHistoryREQ($0, channel: "chan-b") }
        await socket.enqueue(EngineFrames.eose(historyB))

        await waitUntil { await harness.engine.channelSyncState("chan-a") == .synced }
        await waitUntil { await harness.engine.channelSyncState("chan-b") == .fallbackSynced }

        // A live kind-9 on each standing per-channel content sub (EOSE first → live).
        let subA = await awaitChannelContentREQ(on: socket, channel: "chan-a")
        let subB = await awaitChannelContentREQ(on: socket, channel: "chan-b")
        await socket.enqueue(EngineFrames.eose(subA))
        await socket.enqueue(EngineFrames.eose(subB))
        let liveA = try fixtures.message("liveA", in: "chan-a", at: harness.nowSeconds + 500)
        let liveB = try fixtures.message("liveB", in: "chan-b", at: harness.nowSeconds + 500)
        await socket.enqueue(EngineFrames.event(subA, liveA))
        await socket.enqueue(EngineFrames.event(subB, liveB))

        await waitUntil { (try? await harness.store.event(id: liveA.id)) != nil }
        await waitUntil { (try? await harness.store.event(id: liveB.id)) != nil }

        // Rule 4: the synced channel's watermark advanced to the live cursor, past the
        // head the reconcile committed…
        let liveACursor = WindowCursor(createdAt: liveA.createdAt, id: liveA.id)
        await waitUntil { (try? await harness.store.channelWatermark("chan-a")) == liveACursor }
        #expect(try await harness.store.channelWatermark("chan-a") == liveACursor)
        #expect(try await harness.store.channelWatermark("chan-a")
            != WindowCursor(createdAt: headRow.createdAt, id: headRow.id))
        // …and the fallbackSynced channel's watermark held over its still-open gap.
        #expect(try await harness.store.channelWatermark("chan-b") == nil)

        await harness.engine.stop()
    }
}

// MARK: - Test infrastructure

/// The wired pieces a P3-2 test drives directly.
private struct GatedRig {
    let engine: SyncEngine
    let connection: RelayConnection
    let store: BuzzEventStore
}

/// A fully-wired ``SyncEngine`` over scripted fakes with an injectable
/// ``HTTPTransport``. Mirrors ``EngineHarness`` but lets a test supply a transport
/// that delivers window responses out of request order — the control P3-2 needs to
/// resume a superseded generation's fetch *after* the current one has finished.
private func makeGatedEngine(
    path: String,
    identity: PrivateKey,
    relays: [ScriptedRelay],
    transport: some HTTPTransport
) throws -> GatedRig {
    let transports = ScriptedTransportQueue(relays)
    let signer = InMemorySigner(identity)
    let store = try BuzzEventStore(path: path)
    let connection = RelayConnection(
        url: EngineHarness.relayURL,
        signer: signer,
        config: inertEngineConfig(),
        makeTransport: { await transports.next() },
        backoffSleep: { _ in },
        graceSleep: { _ in }
    )
    let subscriptions = SubscriptionManager(
        connection: connection,
        signer: signer,
        config: SubscriptionManagerConfig(batchSize: 1),
        liveFlushSleep: { _ in }
    )
    let windowClient = WindowClient(transport: transport, queryURL: EngineHarness.queryURL, signer: signer)
    let engine = SyncEngine(
        connection: connection,
        subscriptions: subscriptions,
        store: store,
        presence: PresenceStore(),
        windowClient: windowClient,
        signer: signer,
        config: SyncEngineConfig(presenceSweepInterval: .seconds(3600)),
        now: { Date(timeIntervalSince1970: TimeInterval(1_700_000_000)) }
    )
    return GatedRig(engine: engine, connection: connection, store: store)
}

/// A scripted ``HTTPTransport`` that answers each request by its arrival index, so a
/// test can resume requests out of order. ``FakeHTTPTransport`` delivers strictly
/// FIFO, which cannot reproduce "the older generation's fetch returns last".
private actor IndexedHTTPTransport: HTTPTransport {
    private var arrived = 0
    private var waiters: [Int: CheckedContinuation<(Data, Int), Never>] = [:]
    private var buffered: [Int: (Data, Int)] = [:]
    private var deliveredIndices: Set<Int> = []

    func post(body _: Data, to _: URL, headers _: [String: String]) async throws -> (Data, Int) {
        let index = arrived
        arrived += 1
        if let ready = buffered.removeValue(forKey: index) {
            deliveredIndices.insert(index)
            return ready
        }
        return await withCheckedContinuation { continuation in
            waiters[index] = continuation
        }
    }

    /// How many requests have arrived so far.
    var requestCount: Int { arrived }

    /// Whether the request at `index` has received its response.
    func delivered(_ index: Int) -> Bool { deliveredIndices.contains(index) }

    /// Answers the request at arrival `index`, buffering if it has not arrived yet.
    func respond(index: Int, status: Int, body: Data) {
        if let continuation = waiters.removeValue(forKey: index) {
            deliveredIndices.insert(index)
            continuation.resume(returning: (body, status))
        } else {
            buffered[index] = (body, status)
        }
    }
}
