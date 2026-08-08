import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The Drafts screen: what a row says, where pressing it goes, and what deleting does.
@MainActor
@Suite("Drafts screen", .timeLimit(.minutes(1)))
struct DraftsScreenTests {
    private func summary(
        channel: String = "room-1",
        root: String? = nil,
        snippet: String = "half a thought",
        updatedAt: Int64 = 1_000
    ) -> ComposerDraftSummary {
        ComposerDraftSummary(channelID: channel, rootID: root, snippet: snippet, updatedAt: updatedAt)
    }

    private func identity(
        title: String,
        kind: ConversationIdentity.Kind = .channel
    ) -> ConversationIdentity {
        ConversationIdentity(
            channelID: "room-1",
            kind: kind,
            title: title,
            peer: kind == .channel ? nil : "peer",
            picture: nil,
            initials: "D",
            isPrivate: false
        )
    }

    // MARK: - The card

    /// The owner called the Drafts card too loud: a filled glyph and an amber edge say the
    /// same thing twice. A card that can fill its glyph gives the edge up; one that cannot
    /// keeps it, because the edge is then the only thing it has.
    @Test("only a card whose glyph cannot fill spends the accent on its edge")
    func accentOnEdgeOnlyWhereTheGlyphCannotSpeak() {
        #expect(HomeShortcut.threads.signalsWithGlyph == false)
        #expect(HomeShortcut.drafts.signalsWithGlyph)
        #expect(HomeShortcut.later.signalsWithGlyph)

        #expect(HomeShortcutCard.spendsAccentOnEdge(.threads, isCalling: true))
        #expect(!HomeShortcutCard.spendsAccentOnEdge(.drafts, isCalling: true))
        // A card asking for nothing is a hairline, whatever its glyph can do.
        #expect(!HomeShortcutCard.spendsAccentOnEdge(.threads, isCalling: false))
        #expect(!HomeShortcutCard.spendsAccentOnEdge(.drafts, isCalling: false))
    }

    // MARK: - What a row says

    /// The distinction that decides where a press lands, so it has to be readable before
    /// the press: a thread draft and its channel's draft are different things.
    @Test("a thread draft is titled by its thread, a conversation draft by its name")
    func rowTitle() {
        let channel = identity(title: "design")
        #expect(DraftRowText.title(for: summary(), in: channel) == "design")
        #expect(DraftRowText.title(for: summary(root: "opener"), in: channel) == "Thread in design")

        let dm = identity(title: "Allison Drake", kind: .direct)
        #expect(DraftRowText.title(for: summary(), in: dm) == "Allison Drake")
        #expect(DraftRowText.title(for: summary(root: "opener"), in: dm) == "Thread in Allison Drake")
    }

    @Test("the preview is one line, whatever shape the draft is in")
    func rowPreview() {
        #expect(DraftRowText.preview(of: "one line") == "one line")
        // A draft written as a list previews as its first words, not as a blank row.
        #expect(DraftRowText.preview(of: "\n\n- first\n- second") == "- first - second")
        #expect(DraftRowText.preview(of: "  padded  ") == "padded")
        // Unreachable through the composer — a whitespace-only draft is never stored — but
        // a row must never render as an empty second line.
        #expect(DraftRowText.preview(of: "   ") == "Draft")
    }

    /// A draft in a channel's thread has to be tellable from a draft in the channel around
    /// it before the title is read — they are different destinations.
    @Test("a channel thread draws the thread's mark; a channel and a DM draw their own")
    func rowMark() {
        let channel = identity(title: "design")
        #expect(DraftRowMark.glyph(for: summary(), in: channel) == nil)
        #expect(DraftRowMark.glyph(for: summary(root: "opener"), in: channel) == ThreadView.threadGlyph)

        // A face names the person, which is more use than any symbol — including in their
        // threads.
        let dm = identity(title: "Allison Drake", kind: .direct)
        #expect(DraftRowMark.glyph(for: summary(), in: dm) == nil)
        #expect(DraftRowMark.glyph(for: summary(root: "opener"), in: dm) == nil)
    }

    // MARK: - Where a press goes

    @Test("a draft opens the conversation it belongs to, and a thread draft opens the thread")
    func destinations() {
        #expect(DraftDestination.of(summary()) == .conversation(channelID: "room-1"))
        #expect(
            DraftDestination.of(summary(root: "opener"))
                == .thread(root: "opener", channelID: "room-1")
        )
        // A thread carries its channel, so the two are never confused by a shared id.
        #expect(DraftDestination.of(summary(channel: "room-2", root: "room-2")) == .thread(
            root: "room-2",
            channelID: "room-2"
        ))
    }

    /// Both arrivals ask for the keyboard. A draft screen that dropped you into a
    /// conversation with the keyboard down would be a slower sidebar.
    @Test("both routes carry the request to focus the composer")
    func routesFocusTheComposer() {
        let thread = ThreadRoute(
            root: "opener",
            channel: "room-1",
            anchor: DraftDestination.threadLanding,
            focusesComposer: true
        )
        #expect(thread.focusesComposer)
        // The newest reply, not the opener: a draft is the last thing that happened in
        // that thread, and the keyboard is about to cover the bottom of the screen.
        #expect(thread.anchor == .latestReply)

        let row = ChannelListRow(
            id: "room-1",
            name: "design",
            about: nil,
            picture: nil,
            isPrivate: false,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
        let conversation = ConversationRoute(channel: row, focusesComposer: true)
        #expect(conversation.focusesComposer)
        // And it still collapses onto itself rather than stacking — the focus flag must not
        // make the same conversation a second destination.
        #expect(conversation.pushed(onto: [conversation]).count == 1)
    }

    // MARK: - Deleting

    @Test("deleting a row takes it off the list and out of the cache")
    func deleteRemovesFromBoth() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))
        let key = ComposerDraftKey(channel: "room-1")
        drafts.record(MentionDraft(text: "unsent"), for: key)
        await drafts.flush()

        let model = DraftsModel(store: store, drafts: drafts)
        let list = Task { await model.runList() }
        let counting = Task { await model.runCount() }
        defer { list.cancel(); counting.cancel() }
        await waitUntil { model.summaries.count == 1 && model.count == 1 }

        model.delete([model.summaries[0].id])
        // Gone from the list the instant it is pressed, before any write has landed.
        #expect(model.summaries.isEmpty)
        await drafts.flush()

        await waitUntil { model.count == 0 }
        #expect(try store.composerDraftSummaries().isEmpty)
        // The cache is the authority within a session — a delete that left it holding the
        // text would restore the draft on the next visit to that conversation.
        #expect(drafts.draft(for: key).text.isEmpty)
    }

    @Test("delete all empties the list in one go")
    func deleteAll() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))
        for index in 0 ..< 3 {
            drafts.record(MentionDraft(text: "draft \(index)"), for: ComposerDraftKey(channel: "room-\(index)"))
        }
        await drafts.flush()

        let model = DraftsModel(store: store, drafts: drafts)
        let run = Task { await model.runList() }
        defer { run.cancel() }
        await waitUntil { model.summaries.count == 3 }

        model.deleteAll()
        await drafts.flush()

        // Live list, several queued writes: the snapshot that fires on the first delete
        // still holds the other two, and must not put them back. This is the failure the
        // suite found before ``DraftsModel/discarded`` existed.
        #expect(model.summaries.isEmpty)
        await parkBriefly()
        #expect(model.summaries.isEmpty)
        #expect(try store.composerDraftSummaries().isEmpty)
    }

    /// The suppression is keyed to the version deleted, so typing into that conversation
    /// again brings the row back rather than hiding it for the life of the screen.
    @Test("a draft written again after being deleted returns to the list")
    func rewritingAfterDeleteReturns() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))
        let key = ComposerDraftKey(channel: "room-1")
        let model = DraftsModel(store: store, drafts: drafts)
        let run = Task { await model.runList() }
        defer { run.cancel() }

        drafts.record(MentionDraft(text: "first go"), for: key)
        await drafts.flush()
        await waitUntil { model.summaries.count == 1 }

        model.delete([model.summaries[0].id])
        await drafts.flush()
        #expect(model.summaries.isEmpty)

        drafts.record(MentionDraft(text: "second go"), for: key)
        await drafts.flush()
        await waitUntil { model.summaries.count == 1 }
        #expect(model.summaries.first?.snippet == "second go")
    }

    /// The list is the sidebar's count and the screen's rows, so it has to reflect a draft
    /// written from anywhere — including the composer the reader just left.
    @Test("the list is live and newest edit first")
    func listIsLiveAndOrdered() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let drafts = ComposerDrafts(persistence: StoredComposerDrafts(store: store))
        let model = DraftsModel(store: store, drafts: drafts)
        let run = Task { await model.runList() }
        defer { run.cancel() }
        await waitUntil { model.hasLoaded }
        #expect(model.summaries.isEmpty)

        drafts.record(MentionDraft(text: "first"), for: ComposerDraftKey(channel: "room-1"))
        await drafts.flush()
        await waitUntil { model.summaries.count == 1 }

        drafts.record(MentionDraft(text: "second"), for: ComposerDraftKey(channel: "room-2", root: "opener"))
        await drafts.flush()
        await waitUntil { model.summaries.count == 2 }
        #expect(model.summaries.first?.snippet == "second")
        #expect(model.summaries.first?.rootID == "opener")
    }
}
