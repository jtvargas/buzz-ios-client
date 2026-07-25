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

    @Test("the typing indicator string pluralizes")
    func indicatorPluralizes() {
        #expect(TypingIndicator.text(for: []) == nil)
        #expect(TypingIndicator.text(for: ["Alice"]) == "Alice is typing…")
        #expect(TypingIndicator.text(for: ["Alice", "Bob"]) == "Alice and Bob are typing…")
        #expect(TypingIndicator.text(for: ["Alice", "Bob", "Cara"]) == "Several people are typing…")
    }
}
