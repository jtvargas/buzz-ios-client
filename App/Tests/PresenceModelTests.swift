import BuzzKit
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Presence & typing models", .timeLimit(.minutes(1)))
struct PresenceModelTests {
    @Test("the presence model reflects the workspace roster as heartbeats land")
    func presenceReflectsRoster() async throws {
        let store = PresenceStore()
        let alice = try Fixture()
        let model = PresenceModel(store: store)
        let run = Task { await model.run() }
        defer { run.cancel() }

        // Presence is channel-less (S-5): no `h` tag, keyed by pubkey globally.
        await store.apply([try alice.event(.presence, "online")])

        await waitUntil { model.isOnline(alice.pubkey) }
        #expect(model.online == [alice.pubkey])
    }

    @Test("the typing model reflects channel typers and excludes our own echo")
    func typingExcludesSelf() async throws {
        let store = PresenceStore()
        let me = try Fixture()
        let other = try Fixture()
        let model = ChannelTypingModel(channel: "room-1", store: store, selfPubkey: me.pubkey)
        let run = Task { await model.run() }
        defer { run.cancel() }

        await store.apply([
            try other.event(.typing, "", tags: [["h", "room-1"]]),
            try me.event(.typing, "", tags: [["h", "room-1"]]),
        ])

        await waitUntil { model.typers == [other.pubkey] }
        #expect(model.typers == [other.pubkey])
    }

    @Test("a thread's model hears its own thread; the channel's hears the thread too")
    func typingScopesToItsThread() async throws {
        let store = PresenceStore()
        let me = try Fixture()
        let inThread = try Fixture()
        let inChannel = try Fixture()
        let channelModel = ChannelTypingModel(channel: "room-1", store: store, selfPubkey: me.pubkey)
        let threadModel = ChannelTypingModel(
            channel: "room-1",
            thread: "root-1",
            store: store,
            selfPubkey: me.pubkey
        )
        let channelRun = Task { await channelModel.run() }
        let threadRun = Task { await threadModel.run() }
        defer {
            channelRun.cancel()
            threadRun.cancel()
        }

        await store.apply([
            try inThread.event(.typing, "", tags: [["h", "room-1"], ["e", "root-1", "", "reply"]]),
            try inChannel.event(.typing, "", tags: [["h", "room-1"]]),
        ])

        let both = [inThread.pubkey, inChannel.pubkey].sorted()
        await waitUntil { threadModel.typers == [inThread.pubkey] }
        await waitUntil { channelModel.typers == both }
        // The thread is exact: the channel's own writer is not in it. The channel is
        // wide: from there the two are indistinguishable, so it carries both.
        #expect(threadModel.typers == [inThread.pubkey])
        #expect(channelModel.typers == both)
    }

    /// Every arity, against upstream mobile's own switch
    /// (`mobile/lib/features/channels/channel_detail_page/app_bar.dart:17-21`). Four
    /// cases because the interesting one is the third: it names the first typer and
    /// counts the *others*, so three names say "2 others", not "3".
    @Test("the typing indicator string pluralizes")
    func indicatorPluralizes() {
        #expect(TypingIndicator.text(for: []) == nil)
        #expect(TypingIndicator.text(for: ["Alice"]) == "Alice is typing…")
        #expect(TypingIndicator.text(for: ["Alice", "Bob"]) == "Alice and Bob are typing…")
        #expect(
            TypingIndicator.text(for: ["Alice", "Bob", "Cara"]) == "Alice and 2 others are typing…"
        )
        #expect(
            TypingIndicator.text(for: ["Alice", "Bob", "Cara", "Dan"])
                == "Alice and 3 others are typing…"
        )
    }
}
