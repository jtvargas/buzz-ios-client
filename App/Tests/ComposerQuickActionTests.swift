import BuzzKit
@testable import Hive
import Foundation
import Testing

/// The composer's `@` and `#` buttons: what they put in the draft, and where.
///
/// The insertion looks trivial and is not. It has to land at the *caret* rather than at the
/// end of the draft, and the character it inserts only opens a mention when a word starts
/// there — so a trigger pressed against a word has to bring its own space, or the button
/// writes a character into the text and the panel it exists to open never appears.
@MainActor
@Suite("Composer quick actions", .timeLimit(.minutes(1)))
struct ComposerQuickActionTests {
    /// A model with an empty index behind it. Every case here is about the *insertion*; what
    /// the panel then lists is ``ComposerCaretTests``' subject, and one case below checks the
    /// two are joined up.
    private func model(_ store: BuzzEventStore) -> MentionAutocompleteModel {
        MentionAutocompleteModel(channel: "room-1", store: store, selfPubkey: nil)
    }

    @Test("a trigger pressed against a word brings its own space")
    func spaceWhereAWordDoesNotStart() throws {
        let temp = TempStore()
        defer { temp.remove() }
        let autocomplete = model(try temp.open())

        // Against a word: the trigger cannot open a mention there, so a space goes in first.
        var word = MentionDraft(text: "hello")
        autocomplete.update(for: word)
        autocomplete.insertTrigger(.user, into: &word)
        #expect(word.text == "hello @")
        #expect(word.preferredCursor == 7)
        // And the token it opened is real, which is the whole point of the space.
        #expect(word.activeMention(at: 7)?.kind == .user)

        // Already after a space: exactly one space, never two.
        var spaced = MentionDraft(text: "hello ")
        autocomplete.update(for: spaced)
        autocomplete.insertTrigger(.channel, into: &spaced)
        #expect(spaced.text == "hello #")
        #expect(spaced.activeMention(at: 7)?.kind == .channel)

        // A line break opens a word as surely as a space does.
        var newline = MentionDraft(text: "hello\n")
        autocomplete.update(for: newline)
        autocomplete.insertTrigger(.user, into: &newline)
        #expect(newline.text == "hello\n@")

        // An empty draft has nothing to separate from.
        var empty = MentionDraft()
        autocomplete.update(for: empty)
        autocomplete.insertTrigger(.user, into: &empty)
        #expect(empty.text == "@")
        #expect(empty.activeMention(at: 1)?.query.isEmpty == true)
    }

    @Test("it lands at the caret, not at the end of the draft")
    func insertsAtTheCaret() throws {
        let temp = TempStore()
        defer { temp.remove() }
        let autocomplete = model(try temp.open())

        var draft = MentionDraft(text: "say hi to soon")
        autocomplete.update(for: draft)
        // Mid-sentence, right after "to ".
        autocomplete.updateSelection(NSRange(location: 10, length: 0))
        autocomplete.insertTrigger(.user, into: &draft)

        #expect(draft.text == "say hi to @soon")
        #expect(draft.preferredCursor == 11)
        // The words after the caret are none of the new token's business.
        let mention = try #require(draft.activeMention(at: 11))
        #expect(mention.range == NSRange(location: 10, length: 1))
        #expect(mention.query.isEmpty)
    }

    @Test("a caret already inside a token of that kind gets nothing")
    func noSecondTrigger() throws {
        let temp = TempStore()
        defer { temp.remove() }
        let autocomplete = model(try temp.open())

        // The panel is already open on `@ad`. A second `@` would push a bare trigger in
        // beside it and close the panel this button exists to open.
        var typing = MentionDraft(text: "@ad")
        autocomplete.update(for: typing)
        autocomplete.insertTrigger(.user, into: &typing)
        #expect(typing.text == "@ad")

        // Pressing the *other* trigger there is a change of mind, not a repeat, and is
        // honoured — with its space, since `d` does not open a word.
        autocomplete.insertTrigger(.channel, into: &typing)
        #expect(typing.text == "@ad #")
        #expect(typing.activeMention(at: 5)?.kind == .channel)
    }

    @Test("an inserted trigger carries the tokens after it along with the text")
    func tokensShift() throws {
        let temp = TempStore()
        defer { temp.remove() }
        let autocomplete = model(try temp.open())

        // A finished mention, then a trigger inserted in front of it.
        var draft = MentionDraft(text: "@ad")
        draft.insert(
            .user(MentionCandidateProfile(
                pubkey: String(repeating: "a", count: 64),
                displayName: "Ada Lovelace",
                isAgent: false,
                isChannelMember: true
            )),
            replacing: try #require(draft.activeMention(at: 3)).range
        )
        #expect(draft.text == "@Ada Lovelace ")
        let token = try #require(draft.tokens.first)
        #expect(token.range == NSRange(location: 0, length: 13))

        autocomplete.update(for: draft)
        autocomplete.updateSelection(NSRange(location: 0, length: 0))
        autocomplete.insertTrigger(.channel, into: &draft)

        #expect(draft.text == "#@Ada Lovelace ")
        // The identity still covers the name it stands for. A token left at its old offset
        // would tag Ada for a range that now reads `#@Ada Lovelac`.
        #expect(draft.tokens.first?.range == NSRange(location: 1, length: 13))
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "a", count: 64)])
    }

    @Test("the button takes focus and opens the panel on the roster")
    func opensThePanel() async throws {
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

        let autocomplete = model(store)
        let observation = Task { await autocomplete.run() }
        defer { observation.cancel() }

        var draft = MentionDraft()
        autocomplete.update(for: draft)
        #expect(!autocomplete.isComposerFocused)
        autocomplete.insertTrigger(.user, into: &draft)

        // The keyboard is what makes this a shortcut rather than a character: the author
        // presses it and carries on typing.
        #expect(autocomplete.isComposerFocused)
        // A bare trigger opens the full list, so the button and the keystroke reach the same
        // place. The model is told where the caret is by the insertion itself — nothing
        // reports a selection change for an edit the author did not type.
        await waitUntil { autocomplete.suggestions.map(\.label) == ["Ada Lovelace"] }
    }
}
