@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The launch pass that fetches reply bodies for every channel the reader is in.
///
/// # What was wrong
///
/// A `kind:39005` tally tells a thread how many replies it has; only the replies themselves
/// can say what they said and who wrote them. Before this, the only prefetch on the launch
/// path was ``SyncEngine/settleStarterChannels(joined:generation:)``'s, scoped by name to
/// `general` and `welcome-everyone`. In every other channel a reply written while the phone
/// was asleep sat in the tally with no body behind it until the reader opened the thread —
/// the "replies arrive late" half of the defect.
///
/// # Why the first test drives the whole launch and the rest do not
///
/// ``SyncEngine`` has two on-ready paths, chosen by whether a directory client was injected
/// (`SyncEngine.swift:514-519`), and **production always injects one**. A pass wired into
/// the other branch would compile, pass a suite, and never run on a phone. So the wiring is
/// pinned once through the authoritative path, end to end, in a channel that is deliberately
/// not a starter. The loop's own behaviour — paging, its ceiling, and what it does with a
/// socket that stops answering — is then driven directly, which is the only way to script a
/// relay that fails on the third request but not the first two.
@Suite("Launch thread prefetch", .timeLimit(.minutes(1)))
struct LaunchThreadPrefetchTests {
    /// The wiring assertion. `room` is not a starter channel, so before this pass existed
    /// nothing on the launch path asked about its threads at all.
    @Test("a cold launch fetches replies in a channel that is not a starter")
    func launchReachesAnOrdinaryChannel() async throws {
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
        let author = try Fixture()
        let peer = try Fixture()

        let root = try author.message("opener", in: "room", at: 1_000)
        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", "room"], ["name", "Room"]]),
            relay.event(.groupMembers, "", tags: [["d", "room"], ["p", harness.selfPubkey]]),
            root,
            // The relay knows about a reply this device does not hold. That, and only that,
            // is what makes the thread a candidate.
            try Self.summary(for: root.id, in: "room", lastReplyAt: 1_400, from: relay),
        ], phase: .backfill)

        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        try await driveAuth(harness.connection, socket)
        await waitUntil { await harness.engine.state == .running }
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: "room"))
        await directory.succeed(ChannelDirectorySnapshot(events: [], states: ["room": .active]))
        try await start.value

        let request = await Self.prefetchREQ(on: socket, naming: root.id)
        await socket.enqueue(EngineFrames.event(
            request.id, try Self.reply(to: root, in: "room", from: peer, at: 1_400)
        ))
        await socket.enqueue(EngineFrames.eose(request.id))

        // The tally said four and the fetch returned one, unclipped — so the body arrived,
        // was projected, and the local count now speaks for the thread.
        await waitUntil { (try? Self.head(harness.store, in: "room").replyCount) == 1 }

        await harness.engine.stop()
    }

    /// One pass reaches for ``SyncEngineConfig/threadPrefetchRootLimit`` threads. The whole
    /// point of repeating it is that a pass records what it asked about, so the next pass's
    /// candidate query excludes those and returns the ones behind them — the loop pages down
    /// the backlog rather than re-asking the same question.
    @Test("the loop pages past one pass's root budget")
    func theLoopPagesPastOnePassBudget() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            threadPrefetchRootLimit: 2,
            threadPrefetchLaunchPasses: 3
        )
        try await Self.bootstrap(harness, socket)
        let roots = try await Self.seedCandidates(harness, count: 5)

        let generation = await harness.engine.readyGeneration
        let settled = Task { await harness.engine.settleThreadPrefetch(generation: generation) }
        // Two, two, then one: the third pass comes back short of the budget, which is how
        // the loop learns the backlog is exhausted without spending a fourth query on it.
        var asked: Set<String> = []
        var answered: Set<String> = []
        for expected in [2, 2, 1] {
            let request = await Self.prefetchREQ(on: socket, filters: expected, excluding: answered)
            answered.insert(request.id)
            asked.formUnion(request.filters.compactMap { $0.tagQueries["e"]?.first })
            await socket.enqueue(EngineFrames.eose(request.id))
        }
        await settled.value

        #expect(asked == Set(roots))
        await harness.engine.stop()
    }

    /// The budget is passes × roots and it is a real ceiling, not a target. A device that has
    /// been away long enough to be behind on more than that leaves the rest for the next
    /// launch rather than spending an unbounded launch on it.
    @Test("the pass ceiling stops the loop with candidates still outstanding")
    func theCeilingStopsTheLoop() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            threadPrefetchRootLimit: 2,
            threadPrefetchLaunchPasses: 2
        )
        try await Self.bootstrap(harness, socket)
        _ = try await Self.seedCandidates(harness, count: 6)

        let generation = await harness.engine.readyGeneration
        let settled = Task { await harness.engine.settleThreadPrefetch(generation: generation) }
        var answered: Set<String> = []
        for _ in 0 ..< 2 {
            let request = await Self.prefetchREQ(on: socket, filters: 2, excluding: answered)
            answered.insert(request.id)
            await socket.enqueue(EngineFrames.eose(request.id))
        }
        await settled.value

        // Four of the six, in two requests. Two passes, not three, and not a loop that runs
        // until the candidate list is empty.
        #expect(await Self.prefetchREQCount(on: socket) == 2)
        let remaining = try harness.store.threadPrefetchCandidates(channel: nil, limit: 20)
        #expect(remaining.count == 2)

        await harness.engine.stop()
    }

    /// The trap in looping over this pass. A pass that lost its socket recorded nothing for
    /// the batch it died in, so those roots are still candidates — a loop that reads "the
    /// candidate list did not shrink" as "keep going" spends its whole ceiling putting the
    /// same question to a relay that has just refused to answer it, at the flakiest moment
    /// in the app's life. `interrupted` and `drained` are separate outcomes for this reason.
    @Test("a closed subscription stops the loop rather than re-asking")
    func aClosedSubscriptionStopsTheLoop() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [socket],
            threadPrefetchRootLimit: 2,
            threadPrefetchLaunchPasses: 3
        )
        try await Self.bootstrap(harness, socket)
        _ = try await Self.seedCandidates(harness, count: 6)

        let generation = await harness.engine.readyGeneration
        let settled = Task { await harness.engine.settleThreadPrefetch(generation: generation) }
        let request = await Self.prefetchREQ(on: socket, filters: 2)
        await socket.enqueue(EngineFrames.closed(request.id, "error: no"))
        await settled.value

        // One request, not three. And nothing was recorded against the batch that failed, so
        // every candidate is still one — the next launch asks again from the same place.
        #expect(await Self.prefetchREQCount(on: socket) == 1)
        #expect(try harness.store.threadPrefetchCandidates(channel: nil, limit: 20).count == 6)

        await harness.engine.stop()
    }

    /// A device that is behind on nothing spends one local query and no requests at all —
    /// which is what makes running this on every authoritative pass, rather than once per
    /// install, affordable.
    @Test("a device behind on nothing sends no request")
    func nothingToFetchAsksNothing() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        try await Self.bootstrap(harness, socket)

        // Counted over prefetch requests rather than over every frame on the socket: a
        // launch fires presence and subscription traffic from its own detached tasks, so a
        // total-frame assertion here passes or fails on which task won a scheduler race.
        await harness.engine.settleThreadPrefetch(generation: await harness.engine.readyGeneration)
        #expect(await Self.prefetchREQCount(on: socket) == 0)

        await harness.engine.stop()
    }

    // MARK: - Harness

    private static func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// `count` threads in one channel, each with a relay tally naming a reply this device
    /// does not hold — so each is a prefetch candidate, newest first.
    private static func seedCandidates(_ harness: EngineHarness, count: Int) async throws -> [String] {
        let author = try Fixture()
        let relay = try Fixture()
        let roots = try (0 ..< count).map {
            try author.message("opener \($0)", in: "room", at: 1_000 + Int64($0))
        }
        try await harness.store.ingest(
            batch: roots + (try roots.map {
                try summary(for: $0.id, in: "room", lastReplyAt: 1_400, from: relay)
            }),
            phase: .backfill
        )
        return roots.map(\.id)
    }

    /// A prefetch REQ: every filter names exactly one root by `e`. Matched on the filter
    /// count too, so this cannot return a window request, the standing content sub, or a
    /// one-filter `openThread`.
    private static func prefetchREQ(
        on relay: ScriptedRelay,
        filters: Int,
        excluding seen: Set<String> = []
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame), !seen.contains(request.id) else { continue }
                guard isPrefetch(request.filters), request.filters.count == filters else { continue }
                return request
            }
            await Task.yield()
        }
    }

    /// The prefetch REQ naming one particular root — how the end-to-end launch test finds
    /// its own request among a launch's worth of traffic.
    private static func prefetchREQ(
        on relay: ScriptedRelay,
        naming root: String
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame), isPrefetch(request.filters) else { continue }
                if request.filters.contains(where: { $0.tagQueries["e"] == [root] }) { return request }
            }
            await Task.yield()
        }
    }

    private static func prefetchREQCount(on relay: ScriptedRelay) async -> Int {
        await relay.frames().compactMap(decodeREQ).filter { isPrefetch($0.filters) }.count
    }

    private static func isPrefetch(_ filters: [Filter]) -> Bool {
        !filters.isEmpty && filters.allSatisfy {
            $0.tagQueries["e"]?.count == 1 && $0.kinds == [.channelMessage]
        }
    }

    private static func head(_ store: BuzzEventStore, in channel: String) throws -> TimelineRow {
        let rows = try store.timeline(channel: channel)
        return try #require(rows.first)
    }

    /// A head page holding nothing but its own exhaustion bounds — enough for the reconcile
    /// in front of the prefetch to reach `.synced` without inventing history.
    private static func emptyPage(for channel: String) throws -> Data {
        let build = try WindowResponseBuilder(channel: channel)
        return try WindowResponseBuilder.body([try build.headBounds(hasMore: false)])
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

    private static func reply(
        to root: NostrEvent,
        in channel: String,
        from author: Fixture,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, "a reply",
            tags: [["h", channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }
}

/// A directory whose one answer the test releases when it is ready for it, so the socket is
/// authenticated and the engine running before the pass reconciles against it — an answer
/// that arrived first would make the whole pass a no-op and the test a lie.
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
