import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

@MainActor
@Suite("Typing sender", .timeLimit(.minutes(1)))
struct TypingSenderTests {
    @Test("throttles own typing: rapid input publishes once, a later keystroke republishes")
    func throttles() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let clock = ManualClock()
        let spy = RecordingEphemeralPublisher()
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: StubSender(),
            typing: spy,
            typingThrottle: .seconds(3),
            clock: { clock.current }
        )

        model.handleTyping("h")
        model.handleTyping("he") // within the throttle window: suppressed
        model.handleTyping("hel") // within the throttle window: suppressed
        await waitUntil { await spy.count == 1 }
        #expect(await spy.count == 1)

        // Past the throttle window, the next keystroke republishes.
        clock.advance(by: .seconds(3))
        model.handleTyping("hell")
        await waitUntil { await spy.count == 2 }

        // Every publish is a channel-scoped typing indicator (S-5: the `h` tag is
        // required, or the relay rejects a non-member's typing).
        let publishes = await spy.publishes
        #expect(publishes.allSatisfy {
            $0.kind == .typing && $0.content == "" && $0.tags == [["h", "room-1"]]
        })
    }

    @Test("a thread's composer publishes typing tagged into its own thread")
    func threadComposerPublishesIntoItsThread() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let spy = RecordingEphemeralPublisher()
        let model = ThreadModel(
            root: "root-1",
            channel: "room-1",
            store: store,
            sender: StubSender(),
            opener: StubThreadOpener(store: store, events: []),
            typing: spy,
            selfPubkey: nil
        )

        model.handleTyping("re")

        await waitUntil { await spy.count == 1 }
        // The `h` scope the relay requires, plus the NIP-10 marker that places the
        // indicator in this thread — the same shape the reply it precedes will carry, so
        // a reader in the thread sees it and the channel does not.
        let publishes = await spy.publishes
        #expect(publishes.allSatisfy {
            $0.kind == .typing && $0.content == ""
                && $0.tags == [["h", "room-1"], ["e", "root-1", "", "reply"]]
        })
    }

    @Test("empty or whitespace input never publishes typing")
    func emptyNeverPublishes() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let spy = RecordingEphemeralPublisher()
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: StubSender(),
            typing: spy
        )

        // The empty-input guard returns before spawning any publish task.
        model.handleTyping("")
        model.handleTyping("   ")
        #expect(await spy.count == 0)
    }

    /// A send that keeps its agents mentioned leaves `@Name ` in the composer, and the view
    /// reports every composer change as typing. Clearing used to make that harmless — the
    /// empty guard above caught it — so without a second guard, pressing send would announce
    /// to the whole thread that the author had started typing again.
    @Test("a composer refilled by a send does not publish typing, and the next keystroke does")
    func refillDoesNotPublishTyping() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let spy = RecordingEphemeralPublisher()
        let agent = String(repeating: "b", count: 64)
        let model = ThreadModel(
            root: "root-1",
            channel: "room-1",
            store: store,
            sender: StubSender(),
            opener: StubThreadOpener(store: store, events: []),
            typing: spy,
            selfPubkey: nil
        )

        var draft = MentionDraft(text: "@ag")
        draft.insert(
            .user(MentionCandidateProfile(
                pubkey: agent,
                displayName: "Agent",
                isAgent: true,
                isChannelMember: true
            )),
            replacing: try #require(draft.trailingMention()).range
        )
        draft.replaceCharacters(
            in: NSRange(location: (draft.text as NSString).length, length: 0),
            with: "hello"
        )
        model.mentionDraft = draft
        model.sendReply(keepingAgents: { _ in true })
        #expect(model.mentionDraft.text == "@Agent ")

        // What the view does with that refill: report it as a composer change.
        model.handleTyping(model.mentionDraft.text)
        // Asserted on the throttle stamp rather than on the spy's count, and deliberately:
        // the publish itself happens inside a `Task`, so a count read here is 0 whether or
        // not one was ever spawned. `lastTypingPublish` is written on this actor before that
        // task is started, so it cannot be nil for a publish that is merely still in flight.
        #expect(model.lastTypingPublish == nil)

        // One-shot: the author typing on top of the kept mention publishes as usual.
        model.handleTyping("@Agent and now a question")
        #expect(model.lastTypingPublish != nil)
        await waitUntil { await spy.count == 1 }
        #expect(await spy.count == 1)
    }
}
