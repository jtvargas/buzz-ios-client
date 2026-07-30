@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The shape of the request a thread prefetch puts on the wire.
///
/// # The two defects these pin
///
/// **Starvation.** The obvious way to ask about twenty threads is one filter listing
/// twenty `#e` values. The relay ORs them and applies a single global limit over the
/// merged, `created_at DESC` result (`crates/buzz-db/src/event.rs`), so the busiest thread
/// fills the budget and the other nineteen come back with nothing — which renders exactly
/// like the bug this feature fixes. A REQ's filters are independent queries with
/// independent limits (`crates/buzz-relay/src/handlers/req.rs`), so the ask has to be one
/// filter *per thread*.
///
/// **The filter cap.** The relay's protocol parser rejects a REQ carrying more than ten
/// filters outright (`crates/buzz-relay/src/protocol.rs`, advertised as `max_filters: 10`).
/// It does not degrade — the whole request fails — so batching at ten is a correctness
/// constraint, and a test that only ever sets up one thread would never see it.
@Suite("Thread prefetch request shape", .timeLimit(.minutes(1)))
struct ThreadPrefetchRequestTests {
    private static let channel = "room-1"

    @Test("each thread gets its own filter and its own budget")
    func oneFilterPerThread() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket], threadPrefetchReplyLimit: 7
        )
        let author = try Fixture()
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        let roots = try (0 ..< 3).map { try author.message("opener \($0)", in: Self.channel, at: 1_000 + Int64($0)) }
        _ = try await harness.store.ingest(
            batch: roots + (try roots.map { try Self.summary(for: $0.id, lastReplyAt: 1_400, from: relay) }),
            phase: .backfill
        )

        async let prefetched: Void = harness.engine.prefetchThreads(in: Self.channel)
        let request = await Self.prefetchREQ(on: socket, roots: 3)

        // Three filters, each naming exactly one root, each carrying its own limit. A
        // single filter listing all three would satisfy "the roots are named" and starve.
        #expect(request.filters.count == 3)
        for filter in request.filters {
            #expect(filter.tagQueries["e"]?.count == 1)
            #expect(filter.limit == 7)
            #expect(filter.kinds == [.channelMessage])
        }
        #expect(Set(request.filters.compactMap { $0.tagQueries["e"]?.first }) == Set(roots.map(\.id)))

        await socket.enqueue(EngineFrames.eose(request.id))
        await prefetched
    }

    /// Twelve threads cannot be one REQ. Two is the whole assertion — a single request
    /// would be rejected by the relay's parser and the feature would silently do nothing.
    @Test("more threads than a request may carry are split across requests")
    func batchesRespectTheFilterCap() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let author = try Fixture()
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        let roots = try (0 ..< 12).map { try author.message("opener \($0)", in: Self.channel, at: 1_000 + Int64($0)) }
        _ = try await harness.store.ingest(
            batch: roots + (try roots.map { try Self.summary(for: $0.id, lastReplyAt: 1_400, from: relay) }),
            phase: .backfill
        )

        async let prefetched: Void = harness.engine.prefetchThreads(in: Self.channel)

        let first = await Self.prefetchREQ(on: socket, roots: 10)
        #expect(first.filters.count == SyncEngine.maxFiltersPerRequest)
        await socket.enqueue(EngineFrames.eose(first.id))

        let second = await Self.prefetchREQ(on: socket, roots: 2, excluding: [first.id])
        #expect(second.filters.count == 2)
        await socket.enqueue(EngineFrames.eose(second.id))

        await prefetched
        // Every root was asked about exactly once, across the two requests.
        let asked = (first.filters + second.filters).compactMap { $0.tagQueries["e"]?.first }
        #expect(Set(asked) == Set(roots.map(\.id)))
        #expect(asked.count == 12)
    }

    /// A prefetch that comes back short holds the whole thread, and may say so — the same
    /// claim, on the same evidence, ``SyncEngine/openThread(root:)`` makes. It is what lets
    /// a withdrawn reply lower a count without the reader opening the thread.
    @Test("a thread that fitted inside the budget is held in full")
    func anUnclippedThreadIsClaimed() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket], threadPrefetchReplyLimit: 5
        )
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        // The relay's tally says three; the fetch will return one, because the other two
        // were withdrawn and that correction never reached this device.
        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await harness.store.ingest(
            batch: [root, try Self.summary(for: root.id, count: 3, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )
        #expect(try Self.head(harness.store).replyCount == 3)

        async let prefetched: Void = harness.engine.prefetchThreads(in: Self.channel)
        let request = await Self.prefetchREQ(on: socket, roots: 1)
        await socket.enqueue(EngineFrames.event(request.id, try Self.reply(to: root, from: peer, at: 1_400)))
        await socket.enqueue(EngineFrames.eose(request.id))
        await prefetched

        #expect(try Self.head(harness.store).replyCount == 1)
    }

    /// The other side of the same line: a full page back means there may be more behind it,
    /// so the local count must not be promoted over the relay's larger one.
    @Test("a thread clipped at the budget does not claim to be held in full")
    func aClippedThreadIsNotClaimed() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket], threadPrefetchReplyLimit: 1
        )
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()
        try await Self.bootstrap(harness, socket)

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await harness.store.ingest(
            batch: [root, try Self.summary(for: root.id, count: 30, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )

        async let prefetched: Void = harness.engine.prefetchThreads(in: Self.channel)
        let request = await Self.prefetchREQ(on: socket, roots: 1)
        await socket.enqueue(EngineFrames.event(request.id, try Self.reply(to: root, from: peer, at: 1_400)))
        await socket.enqueue(EngineFrames.eose(request.id))
        await prefetched

        // Thirty, not one.
        #expect(try Self.head(harness.store).replyCount == 30)
    }

    @Test("a device that is not behind on anything sends no request at all")
    func nothingToFetchAsksNothing() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let author = try Fixture()
        try await Self.bootstrap(harness, socket)

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await harness.store.ingest(batch: [root], phase: .backfill)

        let before = await socket.frames().count
        await harness.engine.prefetchThreads(in: Self.channel)
        #expect(await socket.frames().count == before)
    }

    // MARK: - Harness

    private static func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// The prefetch's own REQ: `roots` filters, every one of them naming a root by `e` and
    /// carrying no `since`. Matched on the filter *count* as well as the shape so this does
    /// not return a one-filter `openThread` REQ or the standing content subscription.
    private static func prefetchREQ(
        on relay: ScriptedRelay,
        roots: Int,
        excluding seen: Set<String> = []
    ) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame), !seen.contains(request.id) else { continue }
                let allNameARoot = request.filters.allSatisfy { $0.tagQueries["e"]?.count == 1 }
                if request.filters.count == roots, allNameARoot { return request }
            }
            await Task.yield()
        }
    }

    private static func head(_ store: BuzzEventStore) throws -> TimelineRow {
        let rows = try store.timeline(channel: channel)
        return try #require(rows.first)
    }

    private static func summary(
        for root: String,
        count: Int = 4,
        lastReplyAt: Int64,
        from relay: Fixture
    ) throws -> NostrEvent {
        let content = """
        {"reply_count":\(count),"descendant_count":\(count),\
        "last_reply_at":\(lastReplyAt),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", channel]], at: 1_700_000_500
        )
    }

    private static func reply(to root: NostrEvent, from author: Fixture, at seconds: Int64) throws -> NostrEvent {
        try author.event(
            .channelMessage, "a reply",
            tags: [["h", channel], ["e", root.id, "", "reply"]], at: seconds
        )
    }
}
