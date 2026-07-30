@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// A message's reply tally when this device does not hold the replies.
///
/// # The defect these exist to keep fixed
///
/// Replies are never rows in a channel page — the window request asks for
/// `top_level: true`, which is what NIP-CW is *for*. So the local `thread` table holds
/// only what live fan-out happened to deliver to this device, plus whatever
/// ``SyncEngine/openThread(root:)`` pulled when somebody opened a thread. A tally
/// counted purely from that table is therefore zero for all of history on a cold
/// launch, and a message advertised its own thread **only once you pressed it** — the
/// press being what fetched the replies that made its CTA appear.
///
/// The relay has always been willing to answer this without anybody fetching a reply:
/// a `kind:39005` rides every window page, and a freshly signed one is pushed to
/// channel subscribers on every reply insert and every deletion. The tally now reads
/// that cache, so it no longer depends on holding the replies it counts — which is the
/// property that makes it survive a thread growing without bound.
///
/// These drive the real store through the real ingest, because the point is not that
/// the SQL can add up: it is that a row assembled from a relay summary and no local
/// replies at all comes out advertising its thread.
@Suite("Reply tally from the relay's thread summary", .timeLimit(.minutes(1)))
struct ThreadSummaryTallyTests {
    private static let channel = "room-1"

    /// A relay-signed `kind:39005` in the shape `bridge.rs` and `side_effects.rs` both
    /// emit — one `e`, one `d` (both the root's id), one `h`.
    ///
    /// `descendantCount` defaults to `replyCount` so a test that does not care about
    /// the distinction cannot accidentally assert on a divergence it never set up.
    private func summary(
        for root: String,
        replyCount: Int,
        descendantCount: Int? = nil,
        lastReplyAt: Int64?,
        from relay: Fixture,
        at seconds: Int64 = 1_700_000_500
    ) throws -> NostrEvent {
        let last = lastReplyAt.map(String.init) ?? "null"
        let content = """
        {"reply_count":\(replyCount),"descendant_count":\(descendantCount ?? replyCount),\
        "last_reply_at":\(last),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", Self.channel]], at: seconds
        )
    }

    private func head(_ store: BuzzEventStore) throws -> TimelineRow {
        let rows = try store.timeline(channel: Self.channel)
        return try #require(rows.first)
    }

    // MARK: - The reported defect

    @Test("a message whose replies this device has never seen still advertises its thread")
    func summaryAloneRaisesTheTally() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        // Exactly the cold-launch shape: the window page delivered the top-level row
        // and the relay's tally for it, and *no reply at all* — because a window page
        // does not carry replies and this device has not opened the thread.
        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)
        #expect(try head(store).hasThread == false)

        _ = try await store.ingest(
            batch: [try summary(for: root.id, replyCount: 4, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )

        let row = try head(store)
        #expect(row.replyCount == 4)
        #expect(row.hasThread)
        #expect(row.lastReplyAt == 1_400)
        // And it is still one row: a summary is metadata about a message, never a
        // message. Nothing in the log's 39005 may reach a timeline.
        #expect(try store.timeline(channel: Self.channel).count == 1)
    }

    @Test("a message with no replies and no summary says nothing")
    func silenceStaysSilent() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let row = try head(store)
        #expect(row.replyCount == 0)
        #expect(row.hasThread == false)
        // `nil`, not `0`: a message with no replies has no newest reply, and a `0`
        // there would render as a timestamp in 1970 the first time anything mapped it.
        #expect(row.lastReplyAt == nil)
    }

    // MARK: - Which of the two answers wins

    @Test("the relay's count wins when this device holds fewer replies than exist")
    func summaryWinsOverAThinLocalPicture() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        // One reply arrived live; the other eight are history this device never fetched.
        let seen = try peer.event(
            .channelMessage, "one we have",
            tags: [["h", Self.channel], ["e", root.id, "", "root"], ["e", root.id, "", "reply"]],
            at: 1_100
        )
        _ = try await store.ingest(batch: [root, seen], phase: .backfill)
        #expect(try head(store).replyCount == 1)

        _ = try await store.ingest(
            batch: [try summary(for: root.id, replyCount: 9, lastReplyAt: 1_900, from: relay)],
            phase: .backfill
        )
        #expect(try head(store).replyCount == 9)
    }

    @Test("this device's own count wins when it holds a reply the relay has not tallied yet")
    func localWinsOverAStaleSummary() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(
            batch: [root, try summary(for: root.id, replyCount: 1, lastReplyAt: 1_100, from: relay)],
            phase: .backfill
        )
        #expect(try head(store).replyCount == 1)

        // Three replies this device holds against a summary that still says one. The
        // relay pushes a corrected 39005 for each insert, but it need not have arrived
        // yet — and until it does, a tally must never read as *less* than what this
        // device can already prove.
        let replies = try (0 ..< 3).map { index in
            try peer.event(
                .channelMessage, "r\(index)",
                tags: [["h", Self.channel], ["e", root.id, "", "root"], ["e", root.id, "", "reply"]],
                at: 1_200 + Int64(index)
            )
        }
        _ = try await store.ingest(batch: replies, phase: .live)

        let row = try head(store)
        #expect(row.replyCount == 3)
        #expect(row.lastReplyAt == 1_202)
    }

    @Test("a corrected summary takes the tally back down — a withdrawn reply is not forever")
    func aLowerSummarySupersedesAHigherOne() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(
            batch: [
                root,
                try summary(for: root.id, replyCount: 3, lastReplyAt: 1_300, from: relay, at: 1_700_000_500),
            ],
            phase: .backfill
        )
        #expect(try head(store).replyCount == 3)

        // The relay pushes a fresh 39005 on a deletion too. It is newer, so the
        // projection's latest-wins replaces the count rather than keeping the high
        // water mark — otherwise a thread emptied by its author would advertise
        // replies nobody can open.
        _ = try await store.ingest(
            batch: [
                try summary(for: root.id, replyCount: 1, lastReplyAt: 1_100, from: relay, at: 1_700_000_600),
            ],
            phase: .live
        )

        let row = try head(store)
        #expect(row.replyCount == 1)
        #expect(row.lastReplyAt == 1_100)
    }

    @Test("an older summary arriving late does not disturb the newer one")
    func anOlderSummaryLosesToTheOneAlreadyHeld() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        _ = try await store.ingest(
            batch: [
                root,
                try summary(for: root.id, replyCount: 5, lastReplyAt: 1_500, from: relay, at: 1_700_000_600),
            ],
            phase: .backfill
        )
        // A reconnect can re-deliver a page whose summary predates the live push this
        // device already applied.
        _ = try await store.ingest(
            batch: [
                try summary(for: root.id, replyCount: 2, lastReplyAt: 1_200, from: relay, at: 1_700_000_500),
            ],
            phase: .backfill
        )

        #expect(try head(store).replyCount == 5)
    }

    // MARK: - Which field, and where it reaches

    @Test("the tally is the whole subtree, not the relay's direct-child count")
    func descendantCountIsTheOneThatMatches() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        // The projector records `thread.root_id` as the NIP-10 *root*, so the local
        // count beside this one is the whole subtree. `reply_count` counts direct
        // children only, and picking it would disagree with the local count for
        // exactly the nested replies — an off-by-one that only appears sometimes.
        _ = try await store.ingest(
            batch: [
                root,
                try summary(for: root.id, replyCount: 2, descendantCount: 7, lastReplyAt: 1_700, from: relay),
            ],
            phase: .backfill
        )

        #expect(try head(store).replyCount == 7)
    }

    @Test("the thread's own opener carries the tally too, not just the channel row")
    func theThreadReadAgreesWithTheChannel() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let peer = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: Self.channel, at: 1_000)
        let reply = try peer.event(
            .channelMessage, "r",
            tags: [["h", Self.channel], ["e", root.id, "", "root"], ["e", root.id, "", "reply"]],
            at: 1_100
        )
        _ = try await store.ingest(
            batch: [root, reply, try summary(for: root.id, replyCount: 6, lastReplyAt: 1_600, from: relay)],
            phase: .backfill
        )

        // Both reads are assembled by the same `eventBranch`, and that is the point:
        // two definitions of how many replies a message has is two numbers that
        // eventually disagree on screen.
        let opener = try #require(try store.thread(root: root.id).first)
        #expect(opener.id == root.id)
        #expect(opener.replyCount == 6)
        #expect(try head(store).replyCount == 6)
    }

    @Test("a summary for one message does not raise the message beside it")
    func theTallyIsKeyedToItsOwnRoot() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let quiet = try author.message("quiet", in: Self.channel, at: 1_000)
        let busy = try author.message("busy", in: Self.channel, at: 1_001)
        _ = try await store.ingest(
            batch: [quiet, busy, try summary(for: busy.id, replyCount: 4, lastReplyAt: 1_400, from: relay)],
            phase: .backfill
        )

        let rows = try store.timeline(channel: Self.channel)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID[busy.id]?.replyCount == 4)
        #expect(byID[quiet.id]?.replyCount == 0)
        #expect(byID[quiet.id]?.lastReplyAt == nil)
    }
}

/// The live door the tally arrives through.
///
/// The relay pushes a freshly signed `kind:39005` to channel subscribers on every reply
/// insert and every deletion — expressly so a client can move a badge without
/// refetching the head window. It carries the channel's `h` tag, so it was always
/// addressed to the standing per-channel subscription; the filter's *kind list* was the
/// only reason it never arrived, and a client that does not ask for it drops a push the
/// relay is already paying to send.
@Suite("Thread summaries on the standing content subscription", .timeLimit(.minutes(1)))
struct ThreadSummarySubscriptionTests {
    @Test("a thread summary pushed on the content sub moves the tally with no reply in sight")
    func livePushRaisesTheTally() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(path: database.path, identity: try PrivateKey(), relays: [socket])
        let author = try Fixture()
        let relay = try Fixture()

        try await bootstrap(harness, socket)
        try await harness.engine.subscribeChannelContent("room-1")
        let request = await contentREQ(on: socket, channel: "room-1")

        let root = try author.message("opener", in: "room-1", at: 1_700_000_000)
        await socket.enqueue(EngineFrames.event(request.id, root))
        await socket.enqueue(EngineFrames.eose(request.id))
        await waitUntil { (try? harness.store.timeline(channel: "room-1"))?.isEmpty == false }

        // No reply is ever delivered here — only the relay's word that one exists.
        // That is the whole scalability claim: the badge stops being a function of how
        // many replies this device has downloaded.
        let content = #"{"reply_count":2,"descendant_count":2,"last_reply_at":1700000123,"participants":[]}"#
        let pushed = try relay.event(
            .threadSummary, content,
            tags: [["e", root.id], ["d", root.id], ["h", "room-1"]], at: 1_700_000_130
        )
        await socket.enqueue(EngineFrames.event(request.id, pushed))

        await waitUntil { (try? harness.store.timeline(channel: "room-1"))?.first?.replyCount == 2 }
        let row = try #require(try harness.store.timeline(channel: "room-1").first)
        #expect(row.hasThread)
        #expect(row.lastReplyAt == 1_700_000_123)
    }

    // MARK: - Harness

    /// Starts the engine, completes the auth handshake, answers discovery with no
    /// channels (so no window reconcile is attempted), and waits until running.
    private func bootstrap(_ harness: EngineHarness, _ socket: ScriptedRelay) async throws {
        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)
        await answerDiscovery(on: socket)
        await waitUntil { await harness.engine.state == .running }
    }

    /// The standing content REQ for `channel` on the relay, with its id and filters.
    private func contentREQ(on relay: ScriptedRelay, channel: String) async -> (id: String, filters: [Filter]) {
        while true {
            for frame in await relay.frames() {
                if let request = decodeREQ(frame), isChannelContentREQ(request.filters, channel: channel) {
                    return (request.id, request.filters)
                }
            }
            await Task.yield()
        }
    }
}
