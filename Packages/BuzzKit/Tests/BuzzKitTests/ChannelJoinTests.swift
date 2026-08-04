@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Joining a channel, and the resting cost of the ones nobody joined.
///
/// # What these pin
///
/// The relay serves every open channel to any key, so the directory pass sees channels
/// this identity is not a member of and used to give each one a standing `#h` REQ and a
/// head window out of the same 50 REQ / 5 s budget as the channels the reader reads. The
/// resting set is real membership now, which only works if three things hold together:
/// a discoverable channel buys nothing, a join buys a subscription, and a channel that is
/// visible-but-unjoined still comes alive when it is opened — otherwise the fix trades a
/// budget problem for a channel that silently stops updating.
@Suite("Channel join and membership-scoped subscriptions", .timeLimit(.minutes(1)))
struct ChannelJoinTests {
    // MARK: - The resting set

    @Test("a discoverable channel earns no subscription and no head window; a joined one earns both")
    func onlyMembershipCostsARequest() async throws {
        let socket = ScriptedRelay()
        let directory = ReleasableDirectory()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            directoryClient: TestChannelDirectoryClient(directory)
        )
        let relay = try Fixture()
        let peer = try Fixture()

        // Exactly what the relay hands a key on an open relay: full metadata and a full
        // roster for both channels, this identity named on only one of them.
        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "mine"], ["name", "Mine"]]),
            relay.event(.groupMembers, "", tags: [["d", "mine"], ["p", harness.selfPubkey]]),
            relay.event(.groupMetadata, "", tags: [["d", "stray"], ["name", "Stray"]]),
            relay.event(.groupMembers, "", tags: [["d", "stray"], ["p", peer.pubkey]]),
        ], phase: .backfill)

        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        try await driveAuth(harness.connection, socket)
        await waitUntil { await harness.engine.state == .running }
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "mine"))

        // `.active` for both, which is what `accessStates` produces for an open channel
        // and what the sidebar draws — the point being that the sidebar and the
        // subscription set no longer have to agree.
        await directory.succeed(
            ChannelDirectorySnapshot(events: [], states: ["mine": .active, "stray": .active])
        )
        try await start.value

        await waitUntil { await harness.engine.channelSyncState("mine") == .synced }
        #expect(await harness.engine.channelContentSubscriptions["stray"] == nil)
        #expect(await harness.engine.channelSyncState("stray") == .unsynced)
        // One window request, for the one channel this identity is a member of. The
        // head-reconcile fan-out is the more expensive half and it is scoped by the same
        // set as the subscriptions.
        #expect(await harness.http.requests.count == 1)

        await harness.engine.stop()
    }

    /// The regression the membership scoping would otherwise introduce. Opening a channel
    /// registers nothing of its own — the timeline is purely the read side — so a channel
    /// the reader can still reach but is not a member of would draw its cached history and
    /// then never move again.
    @Test("opening a channel with no standing subscription registers one")
    func openingAnUnjoinedChannelWakesItUp() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        try await Self.bootstrap(harness, socket)

        #expect(await harness.engine.channelContentSubscriptions["stray"] == nil)
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "stray"))
        await harness.engine.setActiveChannel("stray")

        #expect(await harness.engine.channelContentSubscriptions["stray"] != nil)
        _ = await awaitChannelContentREQ(on: socket, channel: "stray")
        // And the head window it has no other route to — detached, so the caller that is
        // presenting a screen never waits on it.
        await waitUntil { await harness.engine.channelSyncState("stray") == .synced }

        await harness.engine.stop()
    }

    // MARK: - The join

    @Test("a join is a kind-9021 carrying only the channel, and it opens the subscription")
    func joinPublishesTheRequestAndSubscribes() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        let join = Task { try await harness.engine.joinChannel("room") }

        let request = await awaitPublishedEvent(on: socket)
        #expect(request.kind == .groupJoinRequest)
        #expect(request.kind.rawValue == 9021)
        // The `h` tag is the whole payload: the relay reads the channel from it and the
        // joiner from the signature, and takes nothing else from a self-join.
        #expect(request.tags == [["h", "room"]])
        await socket.enqueue(EngineFrames.ok(request.id, true))

        // The `#d`-scoped read-back, rather than a race with the best-effort 44100.
        let readBack = await Self.channelStateREQ(on: socket, channel: "room")
        await socket.enqueue(EngineFrames.event(
            readBack.id,
            try relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]])
        ))
        await socket.enqueue(EngineFrames.event(
            readBack.id,
            try relay.event(.groupMembers, "", tags: [["d", "room"], ["p", harness.selfPubkey]])
        ))
        await socket.enqueue(EngineFrames.eose(readBack.id))
        #expect(readBack.filters.allSatisfy { $0.tagQueries["d"] == ["room"] })

        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "room"))
        try await join.value

        #expect(try harness.store.joinedChannelIDs(identity: harness.selfPubkey) == ["room"])
        #expect(await harness.engine.channelContentSubscriptions["room"] != nil)
        #expect(await harness.engine.channelSyncState("room") == .synced)

        await harness.engine.stop()
    }

    /// The ordering that is load-bearing rather than tidy. `threadPrefetchCandidates` joins
    /// the summaries against the roots this device holds, so a reply prefetch issued before
    /// the head window has committed finds no candidates and silently does nothing — a
    /// joined channel with a thread list that stays empty until something else fetches it.
    ///
    /// Asserted by giving the root to the *window* and nothing else: a prefetch REQ naming
    /// it can only exist if the window landed first.
    @Test("hydration pages the window before it asks for replies")
    func hydrationOrdersTheWindowBeforeTheReplies() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        let build = try WindowResponseBuilder(channel: "room")
        let root = try build.row("opener", at: 1_700_000_005)
        let page = try WindowResponseBuilder.body([
            root,
            try Self.summary(for: root.id, in: "room", lastReplyAt: 1_700_000_400, from: relay),
            try build.headBounds(hasMore: false),
        ])

        let join = Task { try await harness.engine.joinChannel("room") }

        let request = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(request.id, true))
        let readBack = await Self.channelStateREQ(on: socket, channel: "room")
        await socket.enqueue(EngineFrames.event(
            readBack.id,
            try relay.event(.groupMembers, "", tags: [["d", "room"], ["p", harness.selfPubkey]])
        ))
        await socket.enqueue(EngineFrames.eose(readBack.id))
        await harness.http.enqueue(status: 200, body: page)

        // Only reachable if the window's root was ingested before the prefetch ran.
        let prefetch = await Self.prefetchREQ(on: socket, root: root.id)
        await socket.enqueue(EngineFrames.eose(prefetch.id))
        try await join.value

        await harness.engine.stop()
    }

    @Test("a refused join is typed, and nothing is subscribed on the way out")
    func refusedJoinIsTypedAndSubscribesNothing() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        try await Self.bootstrap(harness, socket)

        let join = Task { try await harness.engine.joinChannel("hush") }
        let request = await awaitPublishedEvent(on: socket)
        await socket.enqueue(EngineFrames.ok(
            request.id, false, "restricted: channel is private — request an invitation"
        ))

        await #expect(throws: ChannelJoinError.rejected(
            .restricted("channel is private — request an invitation")
        )) {
            try await join.value
        }
        #expect(await harness.engine.channelContentSubscriptions["hush"] == nil)

        await harness.engine.stop()
    }

    // MARK: - Starter channels

    /// The case that never shows up on a device that has been here a while: an identity
    /// that *sees* `general` through open visibility but was never written onto its roster.
    /// Scoping the sidebar to membership takes the channel away from them unless this runs,
    /// and it has to run on launch — an install that already exists never joins a community
    /// again, so a join-time hook would reach nobody who needs it.
    @Test("a launch pass joins a starter channel this identity is not on, exactly once")
    func starterMembershipIsSeededOnLaunch() async throws {
        let socket = ScriptedRelay()
        let directory = ReleasableDirectory()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            directoryClient: TestChannelDirectoryClient(directory)
        )
        let relay = try Fixture()
        let peer = try Fixture()

        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "g"], ["name", "general"]]),
            relay.event(.groupMembers, "", tags: [["d", "g"], ["p", peer.pubkey]]),
            relay.event(.groupMetadata, "", tags: [["d", "w"], ["name", "welcome-everyone"]]),
            relay.event(.groupMembers, "", tags: [["d", "w"], ["p", harness.selfPubkey]]),
        ], phase: .backfill)

        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        try await driveAuth(harness.connection, socket)
        await waitUntil { await harness.engine.state == .running }
        // One for the channel this identity is already a member of, one for the head
        // window the join hydrates with.
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "w"))
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "g"))
        await directory.succeed(
            ChannelDirectorySnapshot(events: [], states: ["g": .active, "w": .active])
        )
        try await start.value

        let request = await awaitPublishedEvent(on: socket)
        #expect(request.kind == .groupJoinRequest)
        // `general` only. The starter set is two channels and this identity was already on
        // the other one's roster, so nothing is published for it.
        #expect(request.tags == [["h", "g"]])
        await socket.enqueue(EngineFrames.ok(request.id, true))

        let readBack = await Self.channelStateREQ(on: socket, channel: "g")
        await socket.enqueue(EngineFrames.event(
            readBack.id,
            try relay.event(
                .groupMembers, "",
                tags: [["d", "g"], ["p", peer.pubkey], ["p", harness.selfPubkey]], at: 1_700_000_100
            )
        ))
        await socket.enqueue(EngineFrames.eose(readBack.id))

        await waitUntil {
            (try? await harness.store.hasSeededStarterChannels(identity: harness.selfPubkey)) == true
        }

        // Marked, so a second pass asks the relay for nothing at all — the whole reason
        // the gate is a per-identity mark rather than a check of the roster it just wrote.
        let published = await publishedEvents(on: socket).count
        await harness.engine.settleStarterChannels(
            joined: try harness.store.joinedChannelIDs(identity: harness.selfPubkey),
            generation: await harness.engine.readyGeneration
        )
        #expect(await publishedEvents(on: socket).count == published)

        await harness.engine.stop()
    }

    // MARK: - Harness

    private static func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// A head page holding nothing but its own exhaustion bounds — enough for a reconcile
    /// to reach `.synced` without inventing history the assertion does not need.
    private static func emptyPage(for channel: String) throws -> Data {
        let build = try WindowResponseBuilder(channel: channel)
        return try WindowResponseBuilder.body([try build.headBounds(hasMore: false)])
    }

    /// The `#d`-scoped group-state read-back for one channel — distinguished from the
    /// one-shot discovery REQ, which carries no `d` at all.
    private static func channelStateREQ(
        on relay: ScriptedRelay,
        channel: String
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame) else { continue }
                if request.filters.allSatisfy({ $0.tagQueries["d"] == [channel] }),
                   !request.filters.isEmpty { return request }
            }
            await Task.yield()
        }
    }

    /// The reply prefetch's REQ, identified by the root it names.
    private static func prefetchREQ(
        on relay: ScriptedRelay,
        root: String
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame) else { continue }
                if request.filters.contains(where: { $0.tagQueries["e"] == [root] }) { return request }
            }
            await Task.yield()
        }
    }

    private static func summary(
        for root: String,
        in channel: String,
        lastReplyAt: Int64,
        from relay: Fixture
    ) throws -> NostrEvent {
        let content = """
        {"reply_count":4,"descendant_count":4,\
        "last_reply_at":\(lastReplyAt),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", channel]], at: 1_700_000_500
        )
    }
}

/// A directory whose one answer the test releases when it is ready for it — so the socket
/// can be authenticated and the engine running before the pass reconciles against it.
private actor ReleasableDirectory: ChannelDirectoryFetching {
    private var waiters: [CheckedContinuation<ChannelDirectorySnapshot, any Error>] = []
    private var answers: [ChannelDirectorySnapshot] = []
    private(set) var requestCount = 0

    func fetch(
        selfPubkey _: String,
        previouslyActiveChannels _: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        requestCount += 1
        if !answers.isEmpty { return answers.removeFirst() }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func succeed(_ snapshot: ChannelDirectorySnapshot) {
        if waiters.isEmpty {
            answers.append(snapshot)
        } else {
            waiters.removeFirst().resume(returning: snapshot)
        }
    }
}
