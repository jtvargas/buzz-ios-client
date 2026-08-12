@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// S-4 on the engine: `markRead` publishes this device's frontier as a channel-less
/// `kind:30078` through the durable outbox and clears the badge optimistically, and
/// an incoming blob (this identity, another device) converges the count through the
/// sink's decrypt path. The global REQ carries the `#h`-less read-state filter.
@Suite("Read state engine", .timeLimit(.minutes(1)))
struct ReadStateEngineTests {
    @Test("markRead publishes a channel-less kind-30078 through the outbox and clears the badge optimistically")
    func markReadPublishesAndClears() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()
        let peer = try Fixture()

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        _ = try await harness.store.ingest(batch: [
            try relay.event(.groupMetadata, #"{"name":"Room"}"#, tags: [["d", "room-1"]], at: 500),
            try peer.message("hi", in: "room-1", at: 3000),
        ], phase: .live)
        try await harness.store.markChannelAccess(
            identity: harness.selfPubkey,
            channel: "room-1",
            state: .active
        )
        try await harness.store.seedMembershipForTest(
            channel: "room-1",
            members: [harness.selfPubkey]
        )
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).first?.unreadCount == 1)

        // `markRead` only records the advance now; the publish follows its coalescing
        // window. Driving `flushReadMarks()` rather than sleeping through the window is the
        // seam that exists for this — a test that waited two seconds would be testing the
        // clock. The flush awaits its drain, which awaits the relay OK, so it runs in a Task
        // the same way the ephemeral and outbox suites drive a durable send.
        await harness.engine.markRead(channel: "room-1", upTo: 3000)
        let mark = Task { await harness.engine.flushReadMarks() }

        // The published event is a well-formed, channel-less NIP-RS blob queued through
        // the outbox (a durable send), never an ephemeral.
        let published = await awaitPublishedReadState(on: socket)
        #expect(published.kind == .readState)
        #expect(published.pubkey == harness.selfPubkey)
        #expect(published.tags.contains { $0.count > 1 && $0[0] == "t" && $0[1] == "read-state" })
        #expect(published.tags.contains { $0.count > 1 && $0[0] == "d" && $0[1].hasPrefix("read-state:") })
        // The load-bearing invariant: read state never carries an `h` tag, so it stays
        // on the global REQ and never masquerades as channel traffic.
        #expect(!published.tags.contains { $0.first == "h" })

        await socket.enqueue(EngineFrames.ok(published.id, true))
        await mark.value

        // Optimistic apply (done before the drain) has cleared the badge; the frontier
        // sits at the newest message.
        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 3000)
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).first?.unreadCount == 0)

        await harness.engine.stop()
    }

    @Test("markRead is grow-only — a mark no newer than the frontier publishes nothing")
    func markReadGrowOnly() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        // The first mark publishes and drains: flush it in a Task and answer the OK.
        await harness.engine.markRead(channel: "room-1", upTo: 3000)
        let mark = Task { await harness.engine.flushReadMarks() }
        let published = await awaitPublishedReadState(on: socket)
        await socket.enqueue(EngineFrames.ok(published.id, true))
        await mark.value
        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 3000)

        // A second mark at or below the frontier. It is recorded — the cheap guard on the way
        // in only compares against the window, not the store — and then dropped at the flush,
        // which is where grow-only actually lives. Flushed rather than left to its timer, so
        // the assertion is about the guard and not about how long the test waited.
        await harness.engine.markRead(channel: "room-1", upTo: 2000)
        await harness.engine.flushReadMarks()
        #expect(try await harness.store.outboxCount() == 0)
        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 3000)

        await harness.engine.stop()
    }

    /// The point of the coalescing window: mark-on-view fires once per arriving message, and
    /// each of those used to be an encrypt, a signature, an outbox row and a relay round trip
    /// in the same serial queue as the reader's own sends.
    @Test("a burst of advances in one channel publishes once, at the newest")
    func burstPublishesOnce() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        for stamp: Int64 in [1000, 2000, 3000, 4000] {
            await harness.engine.markRead(channel: "room-1", upTo: stamp)
        }
        // Nothing has gone out yet — the whole point. Read directly rather than polled: a poll
        // for absence returns on its first pass and proves nothing.
        #expect(try await harness.store.outboxCount() == 0)

        let mark = Task { await harness.engine.flushReadMarks() }
        let published = await awaitPublishedReadState(on: socket)
        await socket.enqueue(EngineFrames.ok(published.id, true))
        await mark.value

        // One publish for four advances, carrying the furthest of them.
        let readStateFrames = await socket.frames().compactMap(publishedEvent).filter { $0.kind == .readState }
        #expect(readStateFrames.count == 1)
        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 4000)

        await harness.engine.stop()
    }

    /// The bonus the old shape could not give: it took one channel per call, so two channels
    /// were always two blobs however close together they were read.
    @Test("advances in several channels collapse into one blob")
    func severalChannelsCollapse() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        await harness.engine.markRead(channel: "room-1", upTo: 3000)
        await harness.engine.markRead(channel: "room-2", upTo: 5000)

        let mark = Task { await harness.engine.flushReadMarks() }
        let published = await awaitPublishedReadState(on: socket)
        await socket.enqueue(EngineFrames.ok(published.id, true))
        await mark.value

        let readStateFrames = await socket.frames().compactMap(publishedEvent).filter { $0.kind == .readState }
        #expect(readStateFrames.count == 1)
        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 3000)
        #expect(try await harness.store.effectiveReadFrontier(context: "room-2") == 5000)

        await harness.engine.stop()
    }

    @Test("an incoming second-device read-state blob converges the unread count through the sink")
    func incomingBlobConverges() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()
        let peer = try Fixture()

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        _ = try await harness.store.ingest(batch: [
            try relay.event(.groupMetadata, #"{"name":"Room"}"#, tags: [["d", "room-1"]], at: 500),
            try peer.message("hi", in: "room-1", at: 3000),
        ], phase: .live)
        try await harness.store.markChannelAccess(
            identity: harness.selfPubkey,
            channel: "room-1",
            state: .active
        )
        try await harness.store.seedMembershipForTest(
            channel: "room-1",
            members: [harness.selfPubkey]
        )
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).first?.unreadCount == 1)

        // A second device of the same identity publishes "read up to 3000". It is
        // encrypted to self and signed by the same key, then fed through the sink.
        let blob = ReadStateBlob(clientID: "desktop", contexts: ["room-1": 3000])
        let ciphertext = try await harness.signer.encryptToSelf(try blob.encodedJSON())
        let event = try await harness.signer.sign(
            kind: .readState,
            content: ciphertext,
            tags: [ReadState.dTag(slotID: "desktop-slot"), ReadState.tTag()],
            createdAt: Date(timeIntervalSince1970: 4000)
        )
        await harness.engine.ingest(batch: [event], subscription: SubscriptionID("global"), phase: .live)

        #expect(try await harness.store.effectiveReadFrontier(context: "room-1") == 3000)
        #expect(try harness.store.channelList(selfPubkey: harness.selfPubkey).first?.unreadCount == 0)

        await harness.engine.stop()
    }

    @Test("the global REQ carries the #h-less read-state filter")
    func globalREQCarriesReadStateFilter() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }

        let filter = await awaitReadStateFilter(on: socket)
        #expect(filter.kinds == [.readState])
        #expect(filter.authors == [harness.selfPubkey])
        #expect(filter.tagQueries["t"] == ["read-state"])
        // #h-less, so the whole global REQ stays global.
        #expect(filter.tagQueries["h"] == nil)

        await harness.engine.stop()
    }

    // MARK: - Helpers

    /// Spins until this client has published a `kind:30078` EVENT frame, returning it.
    private func awaitPublishedReadState(on relay: ScriptedRelay) async -> NostrEvent {
        while true {
            for frame in await relay.frames() {
                if let event = publishedEvent(frame), event.kind == .readState { return event }
            }
            await Task.yield()
        }
    }

    /// Spins until the read-state filter has been sent inside some REQ on `relay`.
    private func awaitReadStateFilter(on relay: ScriptedRelay) async -> Filter {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame),
                   let filter = request.filters.first(where: { $0.kinds == [.readState] }) {
                    return filter
                }
            }
            await Task.yield()
        }
    }
}

// `publishedEvent(_:)` lives with the other client-frame parsers in `ScriptedRelay`.
