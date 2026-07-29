import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// The replies CTA and its tally, live, for rows the head page does not cover.
///
/// A channel timeline holds rows from more than one page: the newest page, re-read on
/// every commit, and whatever paging back brought in behind it. Only the first of those
/// was ever refreshed, so a reply landing on a row from an older page moved nothing a
/// reader could see — the message kept the tally it was fetched with and its replies CTA
/// never appeared, for the life of the screen. Reopening the channel fixed it, which is
/// what made it read as intermittent.
///
/// These drive the real store through the real observation, because the defect was in
/// which rows get re-read and not in the query: every SQL tally here was already correct
/// when asked for directly.
@MainActor
@Suite("Reply metadata, live", .timeLimit(.minutes(1)))
struct ReplyMetadataLiveTests {
    /// A NIP-10 reply to `root`, in the same channel — the shape the projector records a
    /// `thread` row for, and so the shape that moves a tally.
    private func reply(
        _ content: String,
        to root: NostrEvent,
        from author: Fixture,
        at seconds: Int64
    ) throws -> NostrEvent {
        try author.event(
            .channelMessage,
            content,
            tags: [["h", "room-1"], ["e", root.id, "", "reply"]],
            at: seconds
        )
    }

    @Test("a reply to a message older than the head page still raises its replies CTA")
    func replyOutsideHeadWindow() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let peer = try Fixture()

        // Four top-level messages against a page size of two: m0 and m1 are reachable
        // only by paging back, so the head page can never speak for them again.
        let messages = try (0 ..< 4).map {
            try author.message("m\($0)", in: "room-1", at: 1_000 + Int64($0))
        }
        _ = try await store.ingest(batch: messages, phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 2
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.count == 2 }
        await model.loadOlder()
        #expect(model.rows.count == 4)
        #expect(model.rows.first?.content == "m0")
        #expect(model.rows.first?.hasThread == false)

        // The reply itself never enters the channel page — it has a `thread` row, so the
        // page excludes it — which is precisely why the head re-read cannot carry the
        // tally it produced.
        let landed = try reply("re m0", to: messages[0], from: peer, at: 1_010)
        _ = try await store.ingest(batch: [landed], phase: .live)

        await waitUntil { model.rows.first?.replyCount == 1 }
        let row = try #require(model.rows.first)
        #expect(row.content == "m0")
        #expect(row.hasThread)
        #expect(row.lastReplyAt == 1_010)
        // Still four rows: the reply is in its thread, not in the channel.
        #expect(model.rows.count == 4)
    }

    @Test("withdrawing that reply takes the CTA back down again")
    func deletedReplyOutsideHeadWindow() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let peer = try Fixture()

        let messages = try (0 ..< 4).map {
            try author.message("m\($0)", in: "room-1", at: 1_000 + Int64($0))
        }
        let landed = try reply("re m0", to: messages[0], from: peer, at: 1_010)
        _ = try await store.ingest(batch: messages + [landed], phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 2
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.count == 2 }
        await model.loadOlder()
        await waitUntil { model.rows.first?.replyCount == 1 }

        // The replier's own kind-5 naming it: authorized, so the tally drops the reply
        // and the CTA goes with it. Staleness in the other direction — a strip offering a
        // thread with nothing in it — is the same defect.
        let withdrawal = try peer.event(.deletion, "", tags: [["e", landed.id]], at: 1_011)
        _ = try await store.ingest(batch: [withdrawal], phase: .live)

        await waitUntil { model.rows.first?.hasThread == false }
        #expect(model.rows.first?.replyCount == 0)
        #expect(model.rows.first?.lastReplyAt == nil)
    }

    @Test("a reply inside the head page keeps working — the refresh does not disturb it")
    func replyInsideHeadWindow() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let author = try Fixture()
        let peer = try Fixture()

        let root = try author.message("m0", in: "room-1", at: 1_000)
        _ = try await store.ingest(batch: [root], phase: .backfill)

        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: StubSender(), pageSize: 50
        )
        let run = Task { await model.run() }
        defer { run.cancel() }

        await waitUntil { model.rows.count == 1 }
        #expect(model.rows.first?.hasThread == false)

        _ = try await store.ingest(
            batch: [try reply("re m0", to: root, from: peer, at: 1_001)], phase: .live
        )

        await waitUntil { model.rows.first?.replyCount == 1 }
        #expect(model.rows.count == 1)
    }
}
