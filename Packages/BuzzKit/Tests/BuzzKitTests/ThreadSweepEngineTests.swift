@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The sweep as the engine drives it: what it puts on the wire, what stops it repeating,
/// and what it does with a socket that stops answering.
///
/// # Why steady-state cost is the thing under test here
///
/// The sweep's candidates are chosen without consulting the relay, from "roots that exist",
/// and that set does not shrink as it is served. Left alone it would put four requests on
/// the wire on every authoritative pass — launch, foreground, membership change, CLOSED
/// recovery, pull-refresh — forever, on a device that is entirely caught up. The launch
/// prefetch in front of it costs one local query and nothing on the wire once drained, and
/// this has to reach the same place. `noSecondAskOnTheSameSocket` is that assertion and is
/// the most important test in this file.
@Suite("Thread sweep engine", .timeLimit(.minutes(1)))
struct ThreadSweepEngineTests {
    private static let channel = "room"

    /// The shape of the ask. The per-root `since` is what makes it affordable to ask about
    /// forty threads there is no evidence about: an unchanged thread answers with nothing
    /// rather than with its history.
    @Test("each thread is asked about on its own filter, from the newest reply held")
    func theAskCarriesAPerRootSince() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        try await Self.bootstrap(harness, socket)
        let seeded = try await Self.seed(harness, roots: 3, repliesOn: 1)

        let generation = await harness.engine.readyGeneration
        let swept = Task { await harness.engine.settleThreadSweep(generation: generation) }
        let request = await Self.sweepREQ(on: socket, filters: 3)
        await socket.enqueue(EngineFrames.eose(request.id))
        await swept.value

        // One filter per thread. A single filter carrying three `#e` values would OR them
        // under one limit and starve two of the three — the same failure the prefetch's
        // request-shape suite pins, and the reason that shape is copied here rather than
        // simplified.
        #expect(request.filters.count == 3)
        #expect(Set(request.filters.compactMap { $0.tagQueries["e"]?.first }) == Set(seeded.roots))
        for filter in request.filters {
            #expect(filter.kinds == [.channelMessage])
            #expect(filter.tagQueries["e"]?.count == 1)
        }
        // The thread holding a reply asks from that reply; the two holding none ask from
        // their own root. Both are `since` values that let an unchanged thread answer empty.
        let sinceByRoot = Dictionary(
            uniqueKeysWithValues: request.filters.compactMap { filter -> (String, Int64)? in
                guard let root = filter.tagQueries["e"]?.first, let since = filter.since else { return nil }
                return (root, since)
            }
        )
        #expect(sinceByRoot[seeded.roots[0]] == seeded.newestReply)
        #expect(sinceByRoot[seeded.roots[1]] == seeded.rootTimes[1])
        #expect(sinceByRoot[seeded.roots[2]] == seeded.rootTimes[2])

        await harness.engine.stop()
    }

    /// The brake, and the property that makes this safe to run on every authoritative pass
    /// rather than only on cold launch.
    ///
    /// The wait here is a **bounded** one that falls through rather than a spin: if the
    /// second pass did put a request on the wire it would block on an EOSE this test never
    /// sends, and an unbounded wait would turn that regression into a sixty-second hang
    /// wearing a flake's costume instead of a failure that prints.
    ///
    /// **The clock advances between the two passes, and that is what gives the test teeth.**
    /// On the fixed instant every other engine test runs on, `swept_at < staleBefore` is
    /// false whatever `staleBefore` is, so the assertion would hold even if the threshold
    /// were simply "now" — and "now" is the implementation that re-sweeps on every pass, the
    /// exact regression this pins. A minute of drift separates the two.
    @Test("a second pass on the same socket asks nothing at all")
    func noSecondAskOnTheSameSocket() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let clock = SteppableClock(seconds: 1_700_000_000)
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket],
            engineClock: { clock.now }
        )
        try await Self.bootstrap(harness, socket)
        _ = try await Self.seed(harness, roots: 3, repliesOn: 0)

        let generation = await harness.engine.readyGeneration
        let first = Task { await harness.engine.settleThreadSweep(generation: generation) }
        let request = await Self.sweepREQ(on: socket, filters: 3)
        await socket.enqueue(EngineFrames.eose(request.id))
        await first.value
        let afterFirst = await Self.sweepREQCount(on: socket)
        #expect(afterFirst == 1)

        // A minute later, on the same socket — a pull-refresh, a foreground, a membership
        // change. All of these re-enter the same authoritative pass.
        clock.advance(by: 60)

        let done = SweepCompletionProbe()
        let second = Task {
            await harness.engine.settleThreadSweep(generation: generation)
            await done.finish()
        }
        let returned = await waitForBounded { await done.isFinished }
        second.cancel()

        // Returned without asking anything: three roots, all swept on this socket, so the
        // candidate query came back empty and nothing reached the wire.
        #expect(returned)
        #expect(await Self.sweepREQCount(on: socket) == afterFirst)

        await harness.engine.stop()
    }

    /// The other half of the brake. A fresh socket is the evidence that this device was away
    /// and may have missed a reply, so it re-arms the whole sweep — otherwise the brake would
    /// close the very hole it was added to leave open.
    @Test("a restart re-arms the sweep for roots the last run already swept")
    func aRestartReArmsTheSweep() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let identity = try PrivateKey()

        // The first run sweeps three roots and records having done so. Held in scope for the
        // rest of the test rather than scoped away, which is what every other kill-and-reopen
        // suite here does: releasing the first store while the second is running its
        // migration races its pool teardown against that open, and the second harness fails
        // to construct with `database is locked` about one run in four.
        let firstSocket = ScriptedRelay()
        let firstRun = try EngineHarness(
            path: database.path, identity: identity, relays: [firstSocket],
            engineClock: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        try await Self.bootstrap(firstRun, firstSocket)
        _ = try await Self.seed(firstRun, roots: 3, repliesOn: 0)

        let firstGeneration = await firstRun.engine.readyGeneration
        let first = Task { await firstRun.engine.settleThreadSweep(generation: firstGeneration) }
        let opening = await Self.sweepREQ(on: firstSocket, filters: 3)
        let swept = opening.filters.compactMap { $0.tagQueries["e"]?.first }
        await firstSocket.enqueue(EngineFrames.eose(opening.id))
        await first.value
        await firstRun.engine.stop()

        // The same database a minute later, which is a new process and so a new socket. The
        // record survived — it is a local table, not a projection — and the threshold has
        // moved past it, so every root is offered again. Without that the brake would close
        // the very hole it exists to leave open: nothing else ever re-asks about an old
        // thread, which is the whole defect.
        let socket = ScriptedRelay()
        let harness = try EngineHarness(
            path: database.path, identity: identity, relays: [socket],
            engineClock: { Date(timeIntervalSince1970: 1_700_000_060) }
        )
        try await Self.bootstrap(harness, socket)

        let generation = await harness.engine.readyGeneration
        let second = Task { await harness.engine.settleThreadSweep(generation: generation) }
        let request = await Self.sweepREQ(on: socket, filters: 3)
        await socket.enqueue(EngineFrames.eose(request.id))
        await second.value

        #expect(Set(request.filters.compactMap { $0.tagQueries["e"]?.first }) == Set(swept))
        #expect(swept.count == 3)

        await harness.engine.stop()
    }

    /// Nothing is recorded for a batch whose request failed, so those roots stay at the front
    /// of the ordering and the next pass starts exactly where this one stopped. The failure
    /// mode being avoided is counting a dropped socket as "asked, nothing there".
    @Test("a closed subscription leaves the roots unswept")
    func aClosedSubscriptionRecordsNothing() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        try await Self.bootstrap(harness, socket)
        let seeded = try await Self.seed(harness, roots: 3, repliesOn: 0)

        let generation = await harness.engine.readyGeneration
        let swept = Task { await harness.engine.settleThreadSweep(generation: generation) }
        let request = await Self.sweepREQ(on: socket, filters: 3)
        await socket.enqueue(EngineFrames.closed(request.id, "error: no"))
        await swept.value

        // Still candidates, against a threshold far in the future — so nothing was written.
        let remaining = try harness.store.threadSweepCandidates(
            identity: harness.selfPubkey, horizon: 0, staleBefore: 4_000_000_000, limit: 40
        )
        #expect(Set(remaining.map(\.rootID)) == Set(seeded.roots))

        await harness.engine.stop()
    }

    /// The wiring, on the branch production actually takes. `SyncEngine` picks its on-ready
    /// path by whether a directory client was injected, and production always injects one —
    /// so a pass proven only against the other branch would never run on a phone.
    @Test("a cold launch on the authoritative path sweeps")
    func theAuthoritativeLaunchSweeps() async throws {
        let socket = ScriptedRelay()
        let directory = SweepReleasableDirectory()
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
        let root = try author.message("opener", in: Self.channel, at: 1_699_999_000)
        try await harness.store.ingest(batch: [
            relay.event(.groupMetadata, "", tags: [["d", Self.channel], ["name", "Room"]]),
            relay.event(.groupMembers, "", tags: [["d", Self.channel], ["p", harness.selfPubkey]]),
            root,
        ], phase: .backfill)

        let start = Task { try await harness.engine.start() }
        await waitUntil { await directory.requestCount == 1 }
        try await driveAuth(harness.connection, socket)
        await waitUntil { await harness.engine.state == .running }
        await harness.http.enqueue(status: 200, body: try Self.emptyPage(for: Self.channel))
        await directory.succeed(
            ChannelDirectorySnapshot(events: [], states: [Self.channel: .active])
        )
        try await start.value

        // No `thread_summary` for this root anywhere, so the prefetch has no candidate and
        // cannot be what produced this request — a `since`-carrying filter is the sweep's.
        let request = await Self.sweepREQ(on: socket, filters: 1)
        #expect(request.filters.first?.tagQueries["e"] == [root.id])
        #expect(request.filters.first?.since == 1_699_999_000)
        await socket.enqueue(EngineFrames.eose(request.id))

        await harness.engine.stop()
    }

    // MARK: - Harness

    private static func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    private struct Seeded {
        let roots: [String]
        let rootTimes: [Int64]
        let newestReply: Int64
    }

    /// `roots` threads in one joined channel, the first `repliesOn` of them holding a reply.
    /// No `thread_summary` is written for any of them, so nothing here is a *prefetch*
    /// candidate and every request this suite sees is the sweep's.
    private static func seed(_ harness: EngineHarness, roots: Int, repliesOn: Int) async throws -> Seeded {
        let relay = try Fixture()
        let author = try Fixture()
        let times = (0 ..< roots).map { 1_699_999_000 + Int64($0) }
        let openers = try times.map { try author.message("opener \($0)", in: channel, at: $0) }
        let newestReply: Int64 = 1_699_999_500
        let replies = try openers.prefix(repliesOn).map {
            try author.event(
                .channelMessage, "a reply",
                tags: [["h", channel], ["e", $0.id, "", "reply"]], at: newestReply
            )
        }
        try await harness.store.ingest(batch: [
            try relay.event(.groupMetadata, "", tags: [["d", channel], ["name", "Room"]]),
            try relay.event(.groupMembers, "", tags: [["d", channel], ["p", harness.selfPubkey]]),
        ] + openers + replies, phase: .backfill)
        return Seeded(roots: openers.map(\.id), rootTimes: times, newestReply: newestReply)
    }

    /// A sweep REQ: every filter names one root by `e` **and carries a `since`**. The `since`
    /// is what separates it from a prefetch REQ, which never carries one — so this cannot
    /// mistake the pass in front of it for this one.
    private static func isSweep(_ filters: [Filter]) -> Bool {
        !filters.isEmpty && filters.allSatisfy {
            $0.tagQueries["e"]?.count == 1 && $0.kinds == [.channelMessage] && $0.since != nil
        }
    }

    private static func sweepREQ(
        on relay: ScriptedRelay,
        filters: Int,
        excluding seen: Set<String> = []
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame), !seen.contains(request.id) else { continue }
                if isSweep(request.filters), request.filters.count == filters { return request }
            }
            await Task.yield()
        }
    }

    private static func sweepREQCount(on relay: ScriptedRelay) async -> Int {
        await relay.frames().compactMap(decodeREQ).filter { isSweep($0.filters) }.count
    }

    private static func emptyPage(for channel: String) throws -> Data {
        let build = try WindowResponseBuilder(channel: channel)
        return try WindowResponseBuilder.body([try build.headBounds(hasMore: false)])
    }
}

/// A wait that gives up rather than spinning. `waitUntil` never fails — a predicate that
/// never comes true spins to the suite's time limit — which turns a real regression into a
/// hang instead of a failure that prints its value.
func waitForBounded(
    timeout: Duration = .seconds(5),
    _ condition: @escaping @Sendable () async -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() { return true }
        await Task.yield()
    }
    return await condition()
}

/// A clock a test can move. The engine's default test clock is a fixed instant, on which
/// "swept before the threshold" can never become true — so a brake test written on it holds
/// no matter what the threshold is, and proves nothing about which threshold was chosen.
final class SteppableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Int64

    init(seconds: Int64) {
        self.seconds = seconds
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    func advance(by delta: Int64) {
        lock.lock()
        defer { lock.unlock() }
        seconds += delta
    }
}

/// Whether an awaited task got as far as returning — the thing a bounded wait needs to
/// observe, so "the second pass asked nothing" is distinguishable from "the second pass
/// blocked on an EOSE nobody sent".
private actor SweepCompletionProbe {
    private(set) var isFinished = false

    func finish() {
        isFinished = true
    }
}

/// A directory whose one answer the test releases once the socket is authenticated and the
/// engine running — an answer that arrived first would make the pass a no-op.
private actor SweepReleasableDirectory: ChannelDirectoryFetching {
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
