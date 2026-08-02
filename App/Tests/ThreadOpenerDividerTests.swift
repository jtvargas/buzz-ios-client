import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The rule under a thread's opener: the reply count on its leading end, the overflow
/// control on its trailing one.
///
/// # What these tests can and cannot reach
///
/// No UI test drives the thread screen's furniture — `ConversationUITests` covers the
/// scroll, keyboard and reaction shapes and nothing about this line — so nothing here
/// observes a pixel. The arrangement itself (the count left, the ellipsis right, both on
/// the rule that was already there) is reviewed by eye and is called out as unverified
/// rather than covered by a test that only asserts the code says what it says.
///
/// What *is* tested is the pair of decisions behind it: how the count is written, and
/// which tally it is written from. The second is the one worth having: the number is the
/// opener's own ``BuzzKit/TimelineRow/replyCount`` and deliberately not a count of the rows
/// on screen, and the two diverge in situations a reader reaches without trying.
@Suite("Thread opener divider", .timeLimit(.minutes(1)))
struct ThreadOpenerDividerTests {
    // MARK: - How the count is written

    @Test("one reply is singular, and none is nothing at all")
    func labelsTheCount() {
        #expect(ThreadOpenerDivider.replyLabel(for: 1) == "1 reply")
        #expect(ThreadOpenerDivider.replyLabel(for: 2) == "2 replies")
        #expect(ThreadOpenerDivider.replyLabel(for: 17) == "17 replies")

        // Not "0 replies". A thread opened by "Reply in thread" has none yet — that is what
        // it was opened to fix — and furniture reporting its own emptiness under the first
        // message is the state this returns `nil` for. The control beside it still draws:
        // it acts on the opener, which is there either way.
        #expect(ThreadOpenerDivider.replyLabel(for: 0) == nil)
    }

    // MARK: - Which tally it is written from

    @MainActor
    @Test("the count is the opener's own tally, not how many replies are on screen")
    func countIsNotTheRenderedRowCount() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        let first = try reply("first", to: root, by: author, at: 1_001)
        let second = try reply("second", to: root, by: author, at: 1_002)
        _ = try await store.ingest(batch: [root, first, second], phase: .backfill)

        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.map(\.content) == ["root", "first", "second"] }
        #expect(model.replyCount == 2)

        // The reader scrolls up, so the tail freezes at `second`: a reply arriving now is
        // held back deliberately, and the rendered set stops being the thread.
        model.isAtBottom = false
        let third = try reply("third", to: root, by: author, at: 1_003)
        _ = try await store.ingest(batch: [third], phase: .backfill)

        // Waited on through the freeze's own count, deliberately, and not on `replyCount`
        // itself. A wrong tally does not disagree here — it never arrives, so a wait on it
        // would spin until the suite's time limit killed the run sixty seconds later and
        // took every test after it down unreported. The jump pill's count says the arrival
        // has been seen and held, whatever the tally is doing, so the assertion below is
        // reached either way and fails in the ordinary way when it is wrong.
        await waitUntil { model.jump.unreadCount == 1 }

        // The tally moves; the rows do not. Counting `rows` here would draw `2 replies`
        // over a thread that has three — and would then *fall* as the thread grew, which is
        // the failure this assertion exists to catch.
        #expect(model.replyCount == 3)
        #expect(model.rows.map(\.content) == ["root", "first", "second"])
    }

    @MainActor
    @Test("a thread nobody has answered carries no count")
    func openerWithNoRepliesHasNoCount() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        model.primeIfNeeded()

        #expect(model.rows.map(\.content) == ["root"])
        #expect(model.replyCount == 0)
        #expect(ThreadOpenerDivider.replyLabel(for: model.replyCount) == nil)
    }

    @MainActor
    @Test("an own reply still in the outbox is on screen but is not counted")
    func pendingOwnReplyIsNotInTheTally() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let root = try author.message("root", in: "room-1", at: 1_000)
        let landed = try reply("landed", to: root, by: author, at: 1_001)
        _ = try await store.ingest(batch: [root, landed], phase: .backfill)

        let model = ThreadModel(
            root: root.id, channel: "room-1", store: store,
            sender: StubSender(), opener: BlockingThreadOpener(), selfPubkey: author.pubkey
        )
        let run = Task { await model.run() }
        defer { run.cancel() }
        await waitUntil { model.rows.map(\.content) == ["root", "landed"] }
        #expect(model.replyCount == 1)

        // An optimistic own reply: the thread query unions pending outbox rows, so it
        // renders immediately — but the tally counts the `thread` table, which a queued
        // send is not in until the relay accepts it.
        _ = try await store.enqueue(
            content: "queued",
            in: "room-1",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            with: InMemorySigner(author.key)
        )
        await waitUntil { model.rows.map(\.content) == ["root", "landed", "queued"] }

        // Two replies drawn, one counted. This is the channel's own answer to the same
        // question rather than a rule invented for this screen — an undelivered reply is
        // not a reply anybody else has — and it is asserted here so that changing it is a
        // decision somebody makes rather than a regression nobody notices.
        #expect(model.replyCount == 1)
    }

    // MARK: - Helpers

    /// A reply to `root` in the same channel, tagged the way the composer tags one.
    private func reply(
        _ content: String,
        to root: NostrEvent,
        by author: Fixture,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage, content,
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: seconds
        )
    }
}
