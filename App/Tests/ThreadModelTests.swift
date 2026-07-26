import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Thread model", .timeLimit(.minutes(1)))
struct ThreadModelTests {
    @Test("fills on open, then merges a live reply without a manual refresh")
    func mergesLiveReplies() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        let first = try author.event(
            .channelMessage, "first",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_001
        )

        // The opener is already in the store; the one-shot open pulls the first reply.
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let opener = StubThreadOpener(store: store, events: [first])
        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: opener, selfPubkey: author.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        // Opener ingested `first`; the observation renders opener + first reply,
        // oldest-first.
        await waitUntil { model.rows.map(\.content) == ["root", "first"] }

        // A live reply arrives while the thread is open: it merges in place.
        let second = try author.event(
            .channelMessage, "second",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_002
        )
        _ = try await store.ingest(batch: [second], phase: .backfill)

        await waitUntil { model.rows.map(\.content) == ["root", "first", "second"] }
    }

    @Test("renders the opener from the store without waiting on the one-shot fetch")
    func rendersOpenerBeforeFetchReturns() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        // The opener stalls forever: the thread must still fill from the store on the
        // first emission. A gated open (fetch before observe) would leave rows empty
        // until the 3600 s sleep — the very stall that laid the thread out blank and
        // left the scroll gap under the newest message.
        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.map(\.content) == ["root"] }
        #expect(model.hasLoaded)
    }

    @Test("the thread is on screen before any observation fires")
    func primesInInit() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        let reply = try author.event(
            .channelMessage, "reply",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_001
        )
        _ = try await store.ingest(batch: [root, reply], phase: .backfill)

        // No `run()`, so neither the observation nor the one-shot fetch has happened:
        // this is exactly what the scroll view's initial bottom anchor is measured
        // against.
        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        #expect(model.hasLoaded)
        #expect(model.rows.map(\.content) == ["root", "reply"])
        #expect(shape(model.items) == ["root", "reply"])
    }

    @Test("no day separator above the thread's own opener; later days still separate")
    func suppressesTheOpenersOwnSeparator() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let twoDays: Int64 = 2 * 86_400
        let root = try author.message("root", in: "room-1", at: 1_000)
        let sameDay = try author.event(
            .channelMessage, "sameDay",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_060
        )
        let laterDay = try author.event(
            .channelMessage, "laterDay",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_000 + twoDays
        )
        _ = try await store.ingest(batch: [root, sameDay, laterDay], phase: .backfill)

        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        // A thread opens *at* its opener, so a hairline above it labels a boundary the
        // reader never crossed — but a reply on a later day still gets one.
        #expect(shape(model.items) == ["root", "sameDay", "day", "laterDay"])
    }

    @Test("a reply that predates its root keeps the genuine day boundary above it")
    func keepsSeparatorWhenOpenerIsNotFirst() {
        let root = makeRow(id: "root", at: 1_000)
        let early = makeRow(id: "early", at: 900)

        // Relay clock skew, not a thread that opens with its opener: the leading
        // separator is a real day marker for `early` and must survive.
        #expect(shape(ThreadModel.items(for: [early, root], root: "root")) == ["day", "early", "root"])
        // The suppressed case, as a pure check beside it.
        #expect(shape(ThreadModel.items(for: [root], root: "root")) == ["root"])
    }

    @Test("a reply arriving while the reader is up the thread is held back")
    func freezesTailInThread() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: StubThreadOpener(store: store, events: []),
            selfPubkey: author.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.count == 1 }

        model.isAtBottom = false
        _ = try await store.ingest(batch: [
            try author.event(
                .channelMessage, "late",
                tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1_001
            ),
        ], phase: .live)

        await waitUntil { model.heldBackCount == 1 }
        #expect(model.rows.map(\.content) == ["root"])

        model.jumpToLatest()
        #expect(model.heldBackCount == 0)
        #expect(model.rows.map(\.content) == ["root", "late"])
        #expect(model.jumpToken == 1)
    }

    @Test("a reply from the composer threads to the root through the durable path")
    func replyThreadsToRoot() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let sender = try RecordingSender()
        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: sender, opener: StubThreadOpener(store: store, events: []),
            selfPubkey: author.pubkey
        )

        model.draft = "a reply"
        model.sendReply()

        await waitUntil { await sender.sent.count == 1 }
        let sent = try #require(await sender.sent.first)
        #expect(sent.kind == .channelMessage)
        #expect(sent.content == "a reply")
        #expect(sent.channel == "room-1")
        // Direct reply to the thread head: h scope + a single reply marker.
        #expect(sent.tags == [["h", "room-1"], ["e", root.id, "", "reply"]])
        #expect(model.draft.isEmpty)
    }
}
