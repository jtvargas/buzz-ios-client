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
