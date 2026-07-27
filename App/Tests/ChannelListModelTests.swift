import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Channel-list model", .timeLimit(.minutes(1)))
struct ChannelListModelTests {
    @Test("reflects an ingested kind-39000 channel and its latest message without manual refresh")
    func reflectsIngestedChannel() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let author = try Fixture()
        let message = try author.event(
            .channelMessage,
            "hello there",
            tags: [["h", "general"], ["p", relay.pubkey]],
            at: 1_000
        )

        let model = ChannelListModel(store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // The model streams the change in — nothing calls a refresh.
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", picture: "https://x/pic", at: 500),
            message,
        ], phase: .backfill)

        await waitUntil { model.channels.first?.lastMessageSnippet == "hello there" }

        let channel = try #require(model.channels.first)
        #expect(channel.id == "general")
        #expect(channel.name == "General")
        #expect(channel.picture == "https://x/pic")
        #expect(channel.lastMessageID == message.id)
        // No kind-0 profile for the author, so the row falls back to the raw pubkey.
        #expect(channel.lastMessageAuthor == author.pubkey)
        #expect(model.channels.count == 1)
    }

    @Test("unread count reflects others' messages past the frontier and clears live when marked read")
    func unreadCountTracksReadState() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try peer.message("one", in: "general", at: 1_000),
            try peer.message("two", in: "general", at: 2_000),
        ], phase: .backfill)

        await waitUntil { model.channels.first?.unreadCount == 2 }
        #expect(model.channels.first?.hasUnread == true)

        // Marking read up to the newest clears the badge live — `read_state` is tracked
        // by the observation, so no message needs to arrive to refresh the count.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 2_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.channels.first?.unreadCount == 0 }
        #expect(model.channels.first?.hasUnread == false)
    }

    @Test("the mention badge counts only the unread messages addressed to the reader, live")
    func mentionCountTracksReadState() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let peer = try Fixture()
        let reader = try Fixture()

        let model = ChannelListModel(store: store, selfPubkey: reader.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try peer.message("nothing to do with you", in: "general", at: 1_000),
            try peer.event(
                .channelMessage, "hey @reader",
                tags: [["h", "general"], ["p", reader.pubkey]], at: 2_000
            ),
        ], phase: .backfill)

        await waitUntil { model.channels.first?.unreadCount == 2 }
        #expect(model.channels.first?.unreadMentionCount == 1)

        // Reading past the mention clears the badge while an ordinary unread remains
        // behind it — the two counts move independently.
        try await store.applyReadState(
            author: reader.pubkey, slot: "phone", contexts: ["general": 2_000],
            sourceCreatedAt: 10, sourceEventID: "e"
        )
        await waitUntil { model.channels.first?.unreadMentionCount == 0 }
    }

    @Test("a newer message reorders the list live")
    func newerMessageUpdatesPreview() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let author = try Fixture()

        let model = ChannelListModel(store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("general", name: "General", at: 500),
            try author.message("first", in: "general", at: 1_000),
        ], phase: .backfill)
        await waitUntil { model.channels.first?.lastMessageSnippet == "first" }

        _ = try await store.ingest(batch: [
            try author.message("second", in: "general", at: 2_000),
        ], phase: .live)
        await waitUntil { model.channels.first?.lastMessageSnippet == "second" }

        #expect(model.channels.first?.lastMessageAt == 2_000)
    }
}
