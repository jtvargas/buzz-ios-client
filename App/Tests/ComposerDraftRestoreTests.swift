import BuzzKit
@testable import Hive
import NostrCore
import Testing

/// A sender that refuses every send the way an over-ceiling message is refused —
/// before anything is queued, with the error the model restores the draft on.
private struct RefusingSender: MessageSending {
    let error: OutboxError

    func enqueue(
        kind _: EventKind,
        content _: String,
        in _: String,
        tags _: [[String]],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        throw error
    }

    func retry(_: String) async throws { throw error }
    func discard(_: String) async throws { throw error }
}

/// Drafts through the real models: what a conversation opens with, what leaving it keeps,
/// and what sending it clears. The rules asserted here are the ones a person would notice.
@MainActor
@Suite("Composer draft restore", .timeLimit(.minutes(1)))
struct ComposerDraftRestoreTests {
    /// A channel model wired to `drafts`, exactly as ``ChannelTimelineView`` builds it.
    private func channelModel(
        _ channel: String,
        store: BuzzEventStore,
        drafts: ComposerDrafts
    ) -> ChannelTimelineModel {
        ChannelTimelineModel(channel: channel, store: store, sender: StubSender(), drafts: drafts)
    }

    private func threadModel(
        root: String,
        channel: String,
        store: BuzzEventStore,
        drafts: ComposerDrafts
    ) -> ThreadModel {
        ThreadModel(
            root: root,
            channel: channel,
            store: store,
            sender: StubSender(),
            opener: StubThreadOpener(store: store, events: []),
            drafts: drafts,
            selfPubkey: nil
        )
    }

    /// Leave a channel mid-sentence, come back, and the sentence is still there — the
    /// whole ask, at the level a person experiences it. The second model is what a push
    /// actually builds: navigation does not reuse the first one.
    @Test("a channel reopens on the text it was left with")
    func channelRestoresItsOwnDraft() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let first = channelModel("room-1", store: store, drafts: drafts)
        first.primeIfNeeded()
        first.draft = "half a message"
        await drafts.flush()

        let second = channelModel("room-1", store: store, drafts: drafts)
        second.primeIfNeeded()
        #expect(second.draft == "half a message")
    }

    /// The failure JT named: typing in a thread and navigating back to a *different*
    /// conversation must land on an empty composer.
    @Test("a thread's draft never appears in a channel, or in another channel")
    func draftsDoNotLeakAcrossComposers() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let thread = threadModel(root: "opener", channel: "room-1", store: store, drafts: drafts)
        thread.primeIfNeeded()
        thread.draft = "a reply in progress"
        await drafts.flush()

        let sameChannel = channelModel("room-1", store: store, drafts: drafts)
        sameChannel.primeIfNeeded()
        #expect(sameChannel.draft.isEmpty)

        let elsewhere = channelModel("room-2", store: store, drafts: drafts)
        elsewhere.primeIfNeeded()
        #expect(elsewhere.draft.isEmpty)

        // And the thread itself still has it.
        let reopened = threadModel(root: "opener", channel: "room-1", store: store, drafts: drafts)
        reopened.primeIfNeeded()
        #expect(reopened.draft == "a reply in progress")
    }

    @Test("two threads in one channel keep separate drafts")
    func threadsAreIndependent() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let one = threadModel(root: "opener-1", channel: "room-1", store: store, drafts: drafts)
        one.primeIfNeeded()
        one.draft = "for the first thread"
        let two = threadModel(root: "opener-2", channel: "room-1", store: store, drafts: drafts)
        two.primeIfNeeded()
        #expect(two.draft.isEmpty)
        two.draft = "for the second"
        await drafts.flush()

        let reopenedOne = threadModel(root: "opener-1", channel: "room-1", store: store, drafts: drafts)
        reopenedOne.primeIfNeeded()
        #expect(reopenedOne.draft == "for the first thread")
    }

    @Test("sending clears the stored draft, so the composer reopens empty")
    func sendingClearsTheDraft() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let model = channelModel("room-1", store: store, drafts: drafts)
        model.primeIfNeeded()
        model.draft = "about to go"
        await drafts.flush()
        #expect(try store.composerDraft(channel: "room-1", root: nil) != nil)

        model.send()
        await drafts.flush()

        #expect(try store.composerDraft(channel: "room-1", root: nil) == nil)
        let reopened = channelModel("room-1", store: store, drafts: drafts)
        reopened.primeIfNeeded()
        #expect(reopened.draft.isEmpty)
    }

    @Test("clearing the field by hand clears the stored draft too")
    func clearingClearsStorage() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let model = channelModel("room-1", store: store, drafts: drafts)
        model.primeIfNeeded()
        model.draft = "second thoughts"
        await drafts.flush()
        model.draft = ""
        await drafts.flush()

        #expect(try store.composerDraft(channel: "room-1", root: nil) == nil)
    }

    /// The over-ceiling refusal hands the text back to the composer. That restoration is
    /// an edit like any other, so it has to reach storage as well — otherwise a send that
    /// was refused leaves the text on screen and nothing behind it.
    @Test("text handed back by a refused send is stored again")
    func refusedSendKeepsTheDraft() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))

        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: RefusingSender(error: .contentTooLarge(bytes: 70_000, limit: 65_536)),
            drafts: drafts
        )
        model.primeIfNeeded()
        model.draft = "far too long, in principle"
        model.send()
        await waitUntil { model.sendError != nil }
        await drafts.flush()

        #expect(model.draft == "far too long, in principle")
        #expect(try store.composerDraft(channel: "room-1", root: nil)?.text == "far too long, in principle")
    }

    /// Nothing is persisted without a draft store, which is what keeps the UI-test
    /// fixture host and the rest of the suite from writing into a real database.
    @Test("a model built without a draft store keeps nothing")
    func withoutADraftStore() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()

        let model = ChannelTimelineModel(channel: "room-1", store: store, sender: StubSender())
        model.primeIfNeeded()
        model.draft = "typed into the void"

        #expect(try store.composerDrafts().isEmpty)
    }
}
