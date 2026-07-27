import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing

/// The second message on a Threads row: the thread's newest reply.
///
/// # What these tests can and cannot reach
///
/// The Threads screen is not driven by any UI test — `HiveUITests` covers the conversation
/// scroll shapes and nothing above them — so nothing here observes a pixel. What is tested
/// is the part that decides what the view is handed: the cut, the reply's stripped thread
/// tally, and the model resolving refs for *both* of a row's messages rather than only the
/// opener's. The arrangement itself (the reply under the opener, **Reply** under the reply)
/// is reviewed by eye, and is called out as unverified in the pull request rather than
/// covered by a test that only asserts the code says what it says.
@Suite("Threads row", .timeLimit(.minutes(1)))
struct ThreadsRowTests {
    // MARK: - The newest reply as a message

    @Test("the newest reply is cut like the opener and stops claiming a thread of its own")
    func replyIsSummarisedAndFlattened() {
        // A reply that a projector gave its own tally — the shape that would otherwise grow
        // a second replies strip inside a row that already has one, under the opener.
        let long = String(repeating: "a", count: 2_500)
        let reply = ThreadSummary.summarisedReply(
            row("reply", at: 2_000, content: long, replyCount: 3, lastReplyAt: 4_000)
        )

        // The same cut the opener takes: one limit, so a row is never half-capped.
        #expect(reply.content.count == 2_001)
        #expect(reply.content.hasSuffix("\u{2026}"))

        // The tally is what removes the strip — `TimelineRowView` draws it on
        // `replyCount > 0`, so emptying the faces alone would leave an empty strip behind.
        #expect(reply.replyCount == 0)
        #expect(!reply.hasThread)
        // And the timestamp goes with it. It is the time of a reply the tally counted, so a
        // row saying "no replies, last one an hour ago" is a state nothing should be able to
        // reach — `lastReplyDate` is read straight into the strip's label.
        #expect(reply.lastReplyAt == nil)
        #expect(reply.lastReplyDate == nil)

        // Nothing else about the message moves: identity, author, delivery and the reply's
        // own place in the thread are what the row draws its avatar, its name and its tap
        // target from.
        #expect(reply.id == "reply")
        #expect(reply.createdAt == 2_000)
        #expect(reply.pubkey == Self.author)
        #expect(reply.delivery == .sent)
    }

    @Test("the rich body is cut too, because it is the one that renders")
    func replyRichBodyIsCut() {
        let long = String(repeating: "b", count: 2_500)
        let reply = ThreadSummary.summarisedReply(
            row("reply", at: 2_000, content: long, richContent: long)
        )
        #expect(reply.richContent?.count == 2_001)
        #expect(reply.content.count == 2_001)
    }

    @Test("a reply that is already flat and inside the limit is handed back untouched")
    func replyWithinLimitIsUnchanged() {
        // The common case by a wide margin: NIP-10 keeps every reply's `root` tag on the
        // message that opened the thread, so a reply arrives with a zero tally already.
        // Rebuilding it anyway would allocate a new row per reply per commit for nothing,
        // and — because `TimelineRow` is `Hashable` and the model compares snapshots before
        // writing — a row that is `==` to the one before it is what keeps the list still.
        let flat = row("reply", at: 2_000, content: "sounds right to me")
        #expect(ThreadSummary.summarisedReply(flat) == flat)

        // A tally of zero with a stale timestamp beside it is still flattened, so the two
        // fields cannot disagree.
        let stale = row("reply", at: 2_000, content: "sounds right", lastReplyAt: 4_000)
        #expect(ThreadSummary.summarisedReply(stale).lastReplyAt == nil)
    }

    // MARK: - Both messages' mentions

    @Test("the model resolves mentions for the newest reply as well as for the opener")
    @MainActor
    func mentionsResolveForBothShownMessages() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let asker = try Fixture()
        let answerer = try Fixture()
        let reader = try Fixture()

        let model = ThreadsModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // Two messages, each mentioning somebody different. Before the row drew the reply,
        // only the opener's ids went into the batched read — so a reply's `@`-token had no
        // ref to resolve against and rendered as a tinted key prefix or as nothing at all.
        let opener = try asker.event(
            .channelMessage, "what do we do about @reader",
            tags: [["h", "general"], ["p", reader.pubkey]], at: 1_000
        )
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try answerer.event(
                .channelMessage, "middle",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
            try answerer.event(
                .channelMessage, "ask @asker, it was their idea",
                tags: [
                    ["h", "general"],
                    ["e", opener.id, "", "reply"],
                    ["p", asker.pubkey],
                ], at: 3_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)
        #expect(thread.latestReply.content == "ask @asker, it was their idea")
        #expect(model.mentions(for: thread.opener.id).map(\.pubkey) == [reader.pubkey])
        #expect(model.mentions(for: thread.latestReply.id).map(\.pubkey) == [asker.pubkey])
    }

    @Test("a thread with a single reply still has a newest reply to draw")
    @MainActor
    func singleReplyThreadHasAMessageToShow() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let asker = try Fixture()
        let answerer = try Fixture()

        let model = ThreadsModel(store: store, selfPubkey: nil)
        let run = Task { await model.run() }
        defer { run.cancel() }

        let opener = try asker.message("anyone seen the build?", in: "general", at: 1_000)
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            opener,
            try answerer.event(
                .channelMessage, "green as of ten minutes ago",
                tags: [["h", "general"], ["e", opener.id, "", "reply"]], at: 2_000
            ),
        ], phase: .backfill)

        await waitUntil { model.threads.count == 1 }
        let thread = try #require(model.threads.first)

        // The row draws it, and this is the case where that matters most: the strip under
        // the opener says `1 reply` and shows one face, which is a count rather than an
        // answer. The two are not the same message drawn twice — the reply is a different
        // event by a different author, and the opener stays where it is.
        #expect(thread.replyCount == 1)
        #expect(thread.intermediateReplyCount == 0)
        #expect(thread.latestReply.id != thread.opener.id)
        #expect(thread.latestReply.content == "green as of ten minutes ago")
        #expect(thread.latestReply.pubkey == answerer.pubkey)
        // Nothing hangs off the reply itself, so the row's second message brings no second
        // strip with it even before `summarisedReply` has had a say.
        #expect(!ThreadSummary.summarisedReply(thread.latestReply).hasThread)
    }
}

private extension ThreadsRowTests {
    static var author: String { String(repeating: "aa", count: 32) }

    func row(
        _ id: String,
        at createdAt: Int64,
        content: String? = nil,
        richContent: String? = nil,
        replyCount: Int = 0,
        lastReplyAt: Int64? = nil
    ) -> TimelineRow {
        TimelineRow(
            id: id,
            pubkey: Self.author,
            createdAt: createdAt,
            content: content ?? id,
            isEdited: false,
            isDeleted: false,
            richContent: richContent,
            delivery: .sent,
            authorName: nil,
            authorPicture: nil,
            parentID: "root",
            rootID: "root",
            replyCount: replyCount,
            lastReplyAt: lastReplyAt
        )
    }
}
