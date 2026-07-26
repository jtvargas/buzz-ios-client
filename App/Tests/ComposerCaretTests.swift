import BuzzKit
@testable import Hive
import SwiftUI
import Testing
import UIKit

/// Completion anchored to the caret, at all three levels it has to hold at: the pure
/// detection, the panel the detection drives, and the route the caret takes out of UIKit.
///
/// The old detection read from the *end of the draft*, so a mention only completed on the
/// last word of the last line — and nothing told the model the caret had moved at all.
/// Both halves are pinned here.
@MainActor
@Suite("Composer caret", .timeLimit(.minutes(1)))
struct ComposerCaretTests {
    private func candidate(
        _ name: String = "Ada Lovelace",
        pubkey: String = String(repeating: "a", count: 64)
    ) -> MentionSuggestion {
        .user(MentionCandidateProfile(
            pubkey: pubkey,
            displayName: name,
            isAgent: false,
            isChannelMember: true
        ))
    }

    // MARK: - Detection

    @Test("completion follows the caret rather than the end of the draft")
    func caretAnchoredDetection() throws {
        // Mid-sentence: the query runs from the trigger to the caret, and the words after
        // it are none of its business.
        let sentence = MentionDraft(text: "hello @ad world")
        let midway = try #require(sentence.activeMention(at: 9))
        #expect(midway.range == NSRange(location: 6, length: 3))
        #expect(midway.query == "ad")
        #expect(midway.kind == .user)

        // At the very start of a draft.
        #expect(try #require(MentionDraft(text: "@ad rest").activeMention(at: 3)).query == "ad")

        // A caret before the trigger has nothing to complete.
        #expect(sentence.activeMention(at: 6) == nil)
        #expect(sentence.activeMention(at: 0) == nil)

        // The *nearest* trigger before the caret wins — which is not the last trigger in
        // the text. With the caret inside `@ada`, the `#gen` further along is not what is
        // being typed, and completing a person there must not offer channels.
        let two = MentionDraft(text: "@ada #gen")
        let first = try #require(two.activeMention(at: 4))
        #expect(first.kind == .user)
        #expect(first.query == "ada")
        #expect(try #require(two.activeMention(at: 9)).kind == .channel)
    }

    @Test("mentions work across line breaks and inside multiline text")
    func multilineDetection() throws {
        // On the last line, with lines above it.
        #expect(try #require(MentionDraft(text: "first\n@ad").activeMention(at: 9)).query == "ad")
        // On the *first* line, with lines below it — invisible to the old end-of-draft
        // search, which refused any token whose text ran through a newline.
        #expect(try #require(MentionDraft(text: "@ad\nsecond").activeMention(at: 3)).query == "ad")
        // And in the middle of a multiline draft.
        let middle = MentionDraft(text: "one\nsay hi to @ad soon\nthree")
        let mention = try #require(middle.activeMention(at: 17))
        #expect(mention.range == NSRange(location: 14, length: 3))
        #expect(mention.query == "ad")
        // A line break *between* the trigger and the caret still ends the token.
        #expect(MentionDraft(text: "@ad\nmore").activeMention(at: 8) == nil)
    }

    @Test("nothing after the caret can invalidate the query")
    func textAfterTheCaretIsIrrelevant() throws {
        // Double spaces, a line break and another trigger, all after the caret. Every one
        // of them closed the panel before, because detection read to the end of the draft.
        let noisy = MentionDraft(text: "@ad  two  spaces\nand @more")
        let mention = try #require(noisy.activeMention(at: 3))
        #expect(mention.range == NSRange(location: 0, length: 3))
        #expect(mention.query == "ad")
    }

    @Test("whitespace, an unopened trigger, and an overlong query all close the panel")
    func invalidQueries() throws {
        // A space typed straight after a bare trigger closes it — the same rule that keeps
        // a markdown heading a heading.
        #expect(MentionDraft(text: "@ ").activeMention(at: 2) == nil)
        #expect(MentionDraft(text: "# Heading").activeMention(at: 9) == nil)
        // One internal space still completes a multi-word display name; two end the token.
        #expect(try #require(MentionDraft(text: "@Ada Lov").activeMention(at: 8)).query == "Ada Lov")
        #expect(MentionDraft(text: "@Ada  Lov").activeMention(at: 9) == nil)
        // A trigger that does not open a word is not a mention — and neither is anything
        // further back, because the word the caret sits in is already spoken for.
        #expect(MentionDraft(text: "mail@test").activeMention(at: 9) == nil)
        #expect(MentionDraft(text: "@ada mail@test").activeMention(at: 14) == nil)
        // Past the scan bound it gives up rather than walking the draft on every keystroke.
        let overlong = MentionDraft(
            text: "@" + String(repeating: "a", count: MentionDraft.maxTokenLength)
        )
        #expect(overlong.activeMention(at: (overlong.text as NSString).length) == nil)
        let bounded = MentionDraft(text: "@" + String(repeating: "a", count: 32))
        #expect(try #require(bounded.activeMention(at: 33)).query.count == 32)
    }

    @Test("an insertion mid-sentence replaces only the mention and leaves one space")
    func midSentenceInsertion() throws {
        var draft = MentionDraft(text: "hello @ad world")
        let caret = draft.insert(
            candidate(),
            replacing: try #require(draft.activeMention(at: 9)).range
        )

        // Everything before and after the mention survives, and the space already sitting
        // there is *the* space after it: appending a second would leave the author a gap to
        // go back and delete.
        #expect(draft.text == "hello @Ada Lovelace world")
        #expect(caret == 20)
        #expect(draft.preferredCursor == 20)
        #expect(draft.tokens.first?.range == NSRange(location: 6, length: 13))
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "a", count: 64)])
        // The caret is past that space, and the finished token does not reopen the panel.
        #expect(draft.activeMention(at: caret) == nil)

        // Where the next character is not a space — a line break here — the space is added.
        var multiline = MentionDraft(text: "@ad\nnext")
        let end = multiline.insert(
            candidate(),
            replacing: try #require(multiline.activeMention(at: 3)).range
        )
        #expect(multiline.text == "@Ada Lovelace \nnext")
        #expect(end == 14)
    }
}

// MARK: - The panel

extension ComposerCaretTests {
    @Test("the panel follows the caret and closes when the caret leaves the mention")
    func caretDrivenSuggestions() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let member = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("room-1", name: "general"),
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", "room-1"], ["p", member.pubkey]],
                at: 1_001
            ),
            try member.event(.metadata, #"{"display_name":"Ada Lovelace"}"#, at: 900),
        ], phase: .backfill)

        let model = MentionAutocompleteModel(channel: "room-1", store: store, selfPubkey: nil)
        let observation = Task { await model.run() }
        defer { observation.cancel() }

        // A mention typed into the middle of an existing sentence. With the caret at the end
        // of the draft the query is `ad world` and matches nobody; the caret is what makes
        // it `ad`.
        let draft = MentionDraft(text: "hello @ad world")
        model.update(for: draft)
        model.updateSelection(NSRange(location: 9, length: 0))
        await waitUntil { model.suggestions.map(\.label) == ["Ada Lovelace"] }

        // The caret leaves the mention: the panel closes.
        model.updateSelection(NSRange(location: 2, length: 0))
        #expect(model.suggestions.isEmpty)

        // A range selection has no insertion point, so there is nothing to complete — and
        // putting the caret back where it was must still reopen the panel.
        model.updateSelection(NSRange(location: 9, length: 0))
        #expect(model.suggestions.count == 1)
        model.updateSelection(NSRange(location: 6, length: 3))
        #expect(model.suggestions.isEmpty)
        model.updateSelection(NSRange(location: 9, length: 0))
        #expect(model.suggestions.count == 1)

        // Selecting replaces the mention the caret is in and leaves the sentence around it.
        var edited = draft
        model.select(try #require(model.suggestions.first), in: &edited)
        #expect(edited.text == "hello @Ada Lovelace world")
        #expect(edited.preferredCursor == 20)
        #expect(model.suggestions.isEmpty)
    }
}

// MARK: - The route out of UIKit

/// UIKit is the only thing that knows a tap or an arrow key moved the caret, so these
/// drive ``TokenTextView``'s coordinator against a real `UITextView` — the shape
/// ``ComposerGeometryTests`` uses. The defect they guard is a *missing delegate callback*,
/// which no amount of exercising ``MentionDraft`` could catch.
extension ComposerCaretTests {
    /// Stands in for the SwiftUI state the representable is bound to, and records what
    /// completion is told.
    private final class Host {
        var document = MentionDraft()
        var isFocused = false
        var selections: [NSRange] = []
    }

    private struct Wired {
        let host: Host
        let coordinator: TokenTextView.Coordinator
        let view: UITextView
    }

    /// A coordinator wired to a real text view.
    ///
    /// The text is assigned *before* the delegate is attached: a programmatic assignment
    /// can move the selection, and a report from setting the fixture up would be
    /// indistinguishable from the behaviour under test.
    private func wire(
        _ text: String = "",
        onDocumentChange: @escaping (MentionDraft) -> Void = { _ in },
        onCaret: @escaping (NSRange) -> Void = { _ in }
    ) -> Wired {
        let host = Host()
        host.document = MentionDraft(text: text)
        let representable = TokenTextView(
            document: Binding(
                get: { host.document },
                // `MessageComposerView` hands the model every change to the draft through
                // `.onChange(of: document)`; this is that hand-off.
                set: { host.document = $0; onDocumentChange($0) }
            ),
            isFocused: Binding(get: { host.isFocused }, set: { host.isFocused = $0 }),
            placeholder: "Message",
            onSelectionChange: { host.selections.append($0); onCaret($0) }
        )
        let view = UITextView()
        view.font = .preferredFont(forTextStyle: .body)
        view.text = text
        let coordinator = representable.makeCoordinator()
        view.delegate = coordinator
        return Wired(host: host, coordinator: coordinator, view: view)
    }

    /// One native keystroke, in the order UIKit performs it: the delegate is asked, the
    /// text view applies the edit itself, the caret moves, and only then is the change
    /// reported. The order is the point — the caret reaches the delegate while the
    /// published draft is still one edit behind.
    private func type(_ text: String, at range: NSRange, into wired: Wired) {
        let coordinator = wired.coordinator
        let view = wired.view
        guard coordinator.textView(view, shouldChangeTextIn: range, replacementText: text) else {
            return
        }
        view.text = (view.text as NSString).replacingCharacters(in: range, with: text)
        view.selectedRange = NSRange(
            location: range.location + (text as NSString).length,
            length: 0
        )
        coordinator.textViewDidChangeSelection(view)
        coordinator.textViewDidChange(view)
    }

    @Test("a caret move with no edit reaches completion")
    func reportsCaretMove() {
        let wired = wire("hello @ad world")
        wired.view.selectedRange = NSRange(location: 9, length: 0)
        wired.host.selections.removeAll()
        wired.coordinator.textViewDidChangeSelection(wired.view)
        #expect(wired.host.selections == [NSRange(location: 9, length: 0)])
    }

    @Test("a selection describing text the draft has not caught up with is ignored")
    func ignoresInFlightSelection() {
        let wired = wire("hello @ad")
        // UIKit has applied a keystroke and the published draft is one edit behind. This
        // caret belongs to a string completion has never seen; the edit carries the
        // authoritative one a moment later.
        wired.view.text = "hello @ada"
        wired.view.selectedRange = NSRange(location: 10, length: 0)
        wired.host.selections.removeAll()
        wired.coordinator.textViewDidChangeSelection(wired.view)
        #expect(wired.host.selections.isEmpty)
    }

    @Test("a render places the caret without reporting it, and does not stay latched")
    func renderDoesNotReport() {
        let wired = wire()
        let draft = MentionDraft(text: "hello @ad world")
        wired.host.document = draft
        // `render` runs from `updateUIView`, inside SwiftUI's own update pass, and sets
        // `selectedRange` itself. Reporting from there writes observed state back during an
        // update — and whoever asked for the render already knows where the caret is.
        wired.coordinator.render(draft, in: wired.view, selection: 9)
        #expect(wired.host.selections.isEmpty)
        #expect(wired.view.selectedRange == NSRange(location: 9, length: 0))

        // The suppression is scoped to the render: a genuine move afterwards still lands.
        wired.coordinator.textViewDidChangeSelection(wired.view)
        #expect(wired.host.selections == [NSRange(location: 9, length: 0)])
    }

    /// The whole feature in one pass, with every real part wired the way
    /// ``MessageComposerView`` wires them: a tap that moves the caret, a mention typed
    /// there through UIKit's own edit path, the live index filtering on it, and the
    /// selection landing back in the draft.
    @Test("a mention typed into the middle of a sentence completes and inserts")
    func mentionInTheMiddleOfASentence() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let member = try Fixture()
        _ = try await store.ingest(batch: [
            try relay.channelMetadata("room-1", name: "general"),
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", "room-1"], ["p", member.pubkey]],
                at: 1_001
            ),
            try member.event(.metadata, #"{"display_name":"Ada Lovelace"}"#, at: 900),
        ], phase: .backfill)
        let model = MentionAutocompleteModel(channel: "room-1", store: store, selfPubkey: nil)
        let observation = Task { await model.run() }
        defer { observation.cancel() }

        // The composer's own wiring: the draft's changes and the caret's both reach the
        // model, and nothing else does.
        let wired = wire("hello  world", onDocumentChange: model.update, onCaret: model.updateSelection)
        await waitUntil { model.suggestions.isEmpty }

        // A tap between the two spaces, then `@ad` typed there.
        wired.view.selectedRange = NSRange(location: 6, length: 0)
        wired.coordinator.textViewDidChangeSelection(wired.view)
        type("@ad", at: NSRange(location: 6, length: 0), into: wired)
        await waitUntil { model.suggestions.map(\.label) == ["Ada Lovelace"] }

        model.select(try #require(model.suggestions.first), in: &wired.host.document)
        #expect(wired.host.document.text == "hello @Ada Lovelace world")
        #expect(wired.host.document.preferredCursor == 20)
        #expect(wired.host.document.mentionedPubkeys(sender: nil) == [member.pubkey.lowercased()])
        #expect(model.suggestions.isEmpty)
    }

    @Test("typing into the middle of a draft carries the caret it left behind")
    func typingCarriesTheCaret() throws {
        let wired = wire("hello  world")
        // The author taps between the two spaces and types a mention there.
        type("@ad", at: NSRange(location: 6, length: 0), into: wired)

        #expect(wired.host.document.text == "hello @ad world")
        // The draft carries the caret, so completion needs nothing from UIKit for an edit —
        // and while this edit was in flight, nothing was reported.
        #expect(wired.host.document.preferredCursor == 9)
        #expect(wired.host.selections.isEmpty)

        let mention = try #require(wired.host.document.activeMention(at: 9))
        #expect(mention.query == "ad")
        #expect(mention.range == NSRange(location: 6, length: 3))
    }
}
