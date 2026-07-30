import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The reply tally on a live screen, from the two places it can move.
///
/// A tally counted only from replies this device holds reads zero across all of history
/// on a cold launch — a channel page is `top_level: true`, so it never carries a reply —
/// and a message advertised its thread only once you pressed it. The relay answers this
/// without anybody fetching a reply, and these drive the real store through the real
/// observation because the question is not whether the SQL adds up: it is whether the
/// screen moves when the answer changes.
@MainActor
@Suite("Reply tally, live", .timeLimit(.minutes(1)))
struct ReplyTallyLiveTests {
    private func summary(
        for root: String,
        count: Int,
        lastReplyAt: Int64,
        from relay: Fixture,
        at seconds: Int64 = 1_700_000_500
    ) throws -> NostrEvent {
        let content = """
        {"reply_count":\(count),"descendant_count":\(count),\
        "last_reply_at":\(lastReplyAt),"participants":[]}
        """
        return try relay.event(
            .threadSummary, content,
            tags: [["e", root], ["d", root], ["h", "room-1"]], at: seconds
        )
    }

    @Test("a relay tally raises a message's replies CTA with no reply on this device")
    func aSummaryRaisesTheCTALive() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 10
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.count == 1 }
        #expect(model.rows.first?.hasThread == false)

        // The relay pushes a freshly signed 39005 on every reply insert, expressly so a
        // client can move a badge without refetching. No reply is delivered here — only
        // the relay's word that three exist.
        _ = try await store.ingest(
            batch: [try summary(for: root.id, count: 3, lastReplyAt: 1_300, from: relay)],
            phase: .live
        )

        await waitUntil { model.rows.first?.replyCount == 3 }
        #expect(model.rows.first?.hasThread == true)
    }

    @Test("opening a thread that turns out to be empty takes the CTA back down live")
    func anEmptyFetchLowersTheCTALive() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: "room-1", at: 1_000)
        _ = try await store.ingest(
            batch: [root, try summary(for: root.id, count: 2, lastReplyAt: 1_200, from: relay)],
            phase: .backfill
        )

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 10
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.first?.replyCount == 2 }

        // The reader opens the thread and the relay returns nothing: those two replies
        // were withdrawn and the correction the relay pushed never reached this device.
        //
        // This is the one tally change with **no event behind it** — nothing is ingested,
        // so the `event` log does not move. If the change signal did not watch
        // `thread_fetch`, the row would keep advertising two replies that are not there
        // until some unrelated event happened along, which is the shape of a bug that
        // reads as intermittent.
        try await store.recordThreadFetch(root: root.id)

        await waitUntil { model.rows.first?.replyCount == 0 }
        #expect(model.rows.first?.hasThread == false)
    }
}
