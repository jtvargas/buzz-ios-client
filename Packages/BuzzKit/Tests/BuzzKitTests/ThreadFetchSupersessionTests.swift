@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Which of two disagreeing reply tallies is the later word.
///
/// # The failure these exist to prevent
///
/// The obvious composition — show whichever count is larger — is unsound in exactly
/// one direction, and permanently. The relay's `kind:39005` push is fan-out only and
/// **never stored**: one dropped by a full socket buffer (backgrounded, locked, flaky
/// signal) is gone, and nothing re-fetches it. A reconnect's `since:` replay re-queries
/// the relay's persisted store, where the summary was never written; a window reconcile
/// only re-pages above its watermark; and ``SyncEngine/openThread(root:)`` asks for
/// `kind:9` and nothing else. So a *deletion* announced into a dropped frame would
/// leave a withdrawn reply advertised forever — the reader opening the thread, counting
/// fewer replies than the badge claims, and finding no way to correct it.
///
/// The rule instead is that a fetch is itself a word, and the later word wins. Each
/// fetch records which summary it already accounted for, so the read can ask an
/// identity question — *is the summary on file still that one?* — rather than compare
/// the relay's clock against the device's, which is unanswerable honestly.
@Suite("A thread fetch supersedes the summary it accounted for", .timeLimit(.minutes(1)))
struct ThreadFetchSupersessionTests {
    private static let channel = "room-1"

    private func summary(
        for root: String,
        count: Int,
        lastReplyAt: Int64?,
        from relay: Fixture,
        at seconds: Int64 = 1_700_000_500
    ) throws -> NostrEvent {
        let last = lastReplyAt.map(String.init) ?? "null"
        let content = """
        {"reply_count":\(count),"descendant_count":\(count),"last_reply_at":\(last),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", Self.channel]], at: seconds
        )
    }

    private func reply(
        _ text: String,
        to root: String,
        from author: Fixture,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, text,
            tags: [["h", Self.channel], ["e", root, "", "root"], ["e", root, "", "reply"]],
            at: seconds
        )
    }

    private func head(_ store: BuzzEventStore) throws -> TimelineRow {
        try #require(try store.timeline(channel: Self.channel).first)
    }

    // MARK: - The correction the larger-of-the-two rule could never make

    @Test("a summary left high by a dropped deletion comes down when the thread is opened")
    func aFetchBringsAStuckSummaryDown() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        // Three replies existed and the relay said so. Two were then withdrawn — and
        // the corrected 39005 the relay pushed for each never reached this device,
        // which is a state nothing can distinguish from "we simply have not fetched
        // them yet": both look like a local count below the relay's.
        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let survivor = try reply("still here", to: root.id, from: peer, at: 1_100)
        _ = try await store.ingest(
            batch: [root, survivor, try summary(for: root.id, count: 3, lastReplyAt: 1_300, from: relay)],
            phase: .backfill
        )
        #expect(try head(store).replyCount == 3)

        // Opening the thread is what tells the two apart: this device now holds every
        // reply the relay would return, so its own count is the later word and the
        // stale summary stops being consulted.
        try await store.recordThreadFetch(root: root.id)

        let row = try head(store)
        #expect(row.replyCount == 1)
        #expect(row.lastReplyAt == 1_100)
        #expect(row.hasThread)
    }

    @Test("a thread emptied entirely stops advertising replies once opened")
    func aFetchCanTakeTheCTAAwayCompletely() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(
            batch: [root, try summary(for: root.id, count: 2, lastReplyAt: 1_200, from: relay)],
            phase: .backfill
        )
        #expect(try head(store).hasThread)

        // The fetch came back with nothing, so there is nothing there. A rule that
        // could only ever raise a count would leave this message offering a thread
        // that opens empty.
        try await store.recordThreadFetch(root: root.id)

        let row = try head(store)
        #expect(row.replyCount == 0)
        #expect(row.hasThread == false)
        #expect(row.lastReplyAt == nil)
    }

    // MARK: - And the fetch does not silence the relay for good

    @Test("a summary arriving after the fetch is a newer word and counts again")
    func aLaterSummaryIsNotSuperseded() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let held = try reply("mine", to: root.id, from: peer, at: 1_100)
        _ = try await store.ingest(
            batch: [root, held, try summary(for: root.id, count: 4, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )
        try await store.recordThreadFetch(root: root.id)
        #expect(try head(store).replyCount == 1)

        // Six replies arrive over the next month while this device is away. Each one
        // made the relay push a summary, and the next window page recomputes one — so
        // a fetch may never be treated as the final word on a thread, only as the
        // latest word *so far*.
        _ = try await store.ingest(
            batch: [try summary(for: root.id, count: 7, lastReplyAt: 1_900, from: relay, at: 1_700_000_900)],
            phase: .live
        )

        let row = try head(store)
        #expect(row.replyCount == 7)
        #expect(row.lastReplyAt == 1_900)
    }

    @Test("a fetch made before any summary existed does not suppress the first one")
    func aFetchAccountsForNoSummaryWhenThereWasNone() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let held = try reply("mine", to: root.id, from: peer, at: 1_100)
        _ = try await store.ingest(batch: [root, held], phase: .backfill)

        // "No summary" is a legitimate thing for a fetch to have accounted for, and
        // the read compares the two with `IS` rather than `=` for exactly this row:
        // under `=`, NULL against a real id yields NULL, which reads as *superseded*
        // and would silence every relay tally that ever arrived after a fetch.
        try await store.recordThreadFetch(root: root.id)
        #expect(try head(store).replyCount == 1)

        _ = try await store.ingest(
            batch: [try summary(for: root.id, count: 5, lastReplyAt: 1_500, from: relay)],
            phase: .live
        )
        #expect(try head(store).replyCount == 5)
    }

    @Test("a fetch of one thread says nothing about another")
    func supersessionIsKeyedToItsOwnRoot() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let opened = try author.message("opened", in: Self.channel, at: 1_000)
        let untouched = try author.message("untouched", in: Self.channel, at: 1_001)
        _ = try await store.ingest(
            batch: [
                opened, untouched,
                try summary(for: opened.id, count: 3, lastReplyAt: 1_300, from: relay),
                try summary(for: untouched.id, count: 2, lastReplyAt: 1_200, from: relay),
            ],
            phase: .backfill
        )

        try await store.recordThreadFetch(root: opened.id)

        let byID = Dictionary(uniqueKeysWithValues: try store.timeline(channel: Self.channel).map { ($0.id, $0) })
        #expect(byID[opened.id]?.replyCount == 0)
        #expect(byID[untouched.id]?.replyCount == 2)
    }

    // MARK: - A second fetch re-accounts for whatever is on file

    @Test("re-opening a thread accounts for the summary that has since arrived")
    func aSecondFetchSupersedesTheNewerSummary() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let held = try reply("mine", to: root.id, from: peer, at: 1_100)
        _ = try await store.ingest(
            batch: [root, held, try summary(for: root.id, count: 2, lastReplyAt: 1_200, from: relay)],
            phase: .backfill
        )
        try await store.recordThreadFetch(root: root.id)

        // A later summary overrides the fetch, as it should...
        _ = try await store.ingest(
            batch: [try summary(for: root.id, count: 9, lastReplyAt: 1_900, from: relay, at: 1_700_000_900)],
            phase: .live
        )
        #expect(try head(store).replyCount == 9)

        // ...until the reader opens the thread again and this device holds it in full
        // once more. Without this the badge would be permanently inflated by whichever
        // summary happened to arrive last, which is the original bug in a new place.
        try await store.recordThreadFetch(root: root.id)
        #expect(try head(store).replyCount == 1)
    }
}

/// The wiring that makes the supersession above happen in the app rather than only in
/// a store test: opening a thread is the one action that gives this device the whole
/// thread, and it is where the fetch gets recorded.
@Suite("Opening a thread records what this device now holds", .timeLimit(.minutes(1)))
struct OpenThreadRecordsFetchTests {
    private static let channel = "room-1"

    @Test("opening a thread promotes this device's own count over the relay's tally")
    func openThreadRecordsTheFetch() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        try await bootstrap(harness, socket)

        // The cold-launch picture: a top-level row and a relay tally of three, and not
        // one reply on this device.
        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await harness.store.ingest(
            batch: [root, try Self.summary(for: root.id, count: 3, from: relay)],
            phase: .backfill
        )
        #expect(try Self.head(harness.store).replyCount == 3)

        // The reader opens the thread. Only one reply comes back, because the other two
        // were withdrawn and the corrected summary never reached this device.
        async let opened: [NostrEvent] = harness.engine.openThread(root: root.id)
        let request = await Self.threadREQ(on: socket, root: root.id)
        await socket.enqueue(EngineFrames.event(request.id, try Self.reply(to: root.id, from: peer)))
        await socket.enqueue(EngineFrames.eose(request.id))
        #expect(try await opened.count == 1)

        let row = try Self.head(harness.store)
        #expect(row.replyCount == 1)
        #expect(row.lastReplyAt == 1_100)
    }

    @Test("a fetch clipped at the relay's limit does not claim to hold the thread")
    func aTruncatedFetchIsNotRecorded() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket], threadFetchLimit: 1
        )
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        try await bootstrap(harness, socket)

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await harness.store.ingest(
            batch: [root, try Self.summary(for: root.id, count: 40, from: relay)],
            phase: .backfill
        )

        // A full page back means there may be more behind it. Recording that as
        // "this device holds the thread" would suppress the relay's larger and more
        // correct count in favour of a local one that is genuinely short — a thread of
        // forty rendering as a thread of one.
        async let opened: [NostrEvent] = harness.engine.openThread(root: root.id)
        let request = await Self.threadREQ(on: socket, root: root.id)
        await socket.enqueue(EngineFrames.event(request.id, try Self.reply(to: root.id, from: peer)))
        await socket.enqueue(EngineFrames.eose(request.id))
        _ = try await opened

        #expect(try Self.head(harness.store).replyCount == 40)
    }

    // MARK: - Harness

    private func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// The one-shot REQ ``SyncEngine/openThread(root:)`` sends — the only one scoped by
    /// an `e` tag naming this root.
    private static func threadREQ(on relay: ScriptedRelay, root: String) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                guard let request = decodeREQ(frame) else { continue }
                let namesRoot = request.filters.contains { $0.tagQueries["e"]?.contains(root) == true }
                if namesRoot { return request }
            }
            await Task.yield()
        }
    }

    private static func summary(for root: String, count: Int, from relay: Fixture) throws -> NostrEvent {
        let content = """
        {"reply_count":\(count),"descendant_count":\(count),"last_reply_at":1300,"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", Self.channel]], at: 1_700_000_500
        )
    }

    private static func reply(to root: String, from author: Fixture) throws -> NostrEvent {
        try author.event(
            .channelMessage, "the one that survived",
            tags: [["h", Self.channel], ["e", root, "", "root"], ["e", root, "", "reply"]],
            at: 1_100
        )
    }

    private static func head(_ store: BuzzEventStore) throws -> TimelineRow {
        try #require(try store.timeline(channel: Self.channel).first)
    }
}

/// What the planner does with the two tables the tally added.
///
/// Every message on every screen is assembled by `eventBranch`, so a join here that
/// scanned rather than seeked would be paid per row, per page, forever — and would not
/// show up in a correctness suite at all. Both tables are keyed by `root_id` as their
/// primary key, which SQLite indexes; this is the assertion that says the planner
/// actually uses it, rather than the belief that it should.
@Suite("The reply tally's joins are index lookups", .timeLimit(.minutes(1)))
struct ThreadTallyQueryPlanTests {
    @Test("neither the summary nor the fetch table is scanned per row")
    func theTallyJoinsSeek() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let branch = BuzzEventStore.eventBranch(where: "e.h = 'room-1' AND e.kind = 9")
        let plan = try await store
            .strings("EXPLAIN QUERY PLAN \(branch)", column: "detail")
            .compactMap { $0 }

        let summary = try #require(plan.first { $0.contains("thread_summary") })
        let fetch = try #require(plan.first { $0.contains("thread_fetch") })
        // "SEARCH … USING INTEGER PRIMARY KEY" / "USING INDEX sqlite_autoindex_…": a
        // seek. "SCAN thread_summary" would mean the whole table read once per row.
        #expect(summary.hasPrefix("SEARCH"))
        #expect(fetch.hasPrefix("SEARCH"))
        #expect(!plan.contains { $0.hasPrefix("SCAN thread_summary") })
        #expect(!plan.contains { $0.hasPrefix("SCAN thread_fetch") })
    }
}
