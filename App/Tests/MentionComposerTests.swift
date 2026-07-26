import BuzzKit
@testable import Hive
import Foundation
import NostrCore
import Testing

@MainActor
@Suite("Mention composer", .timeLimit(.minutes(1)))
struct MentionComposerTests {
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

    private func channel(
        _ name: String = "general",
        id: String = "room-1",
        isPrivate: Bool = false
    ) -> MentionSuggestion {
        .channel(ChannelSuggestion(id: id, name: name, isPrivate: isPrivate))
    }

    // MARK: - Detection

    @Test("detects a trailing mention without treating an email as one")
    func trailingToken() throws {
        let mention = try #require(MentionDraft(text: "hello @ad").trailingMention())
        #expect(mention.range == NSRange(location: 6, length: 3))
        #expect(mention.query == "ad")
        #expect(mention.kind == .user)
        #expect(MentionDraft(text: "mail@test").trailingMention() == nil)
        #expect(MentionDraft(text: "done @ada  next").trailingMention() == nil)
    }

    @Test("detects a trailing channel token and stops at a double space")
    func trailingChannelToken() throws {
        let mention = try #require(MentionDraft(text: "see #gen").trailingMention())
        #expect(mention.range == NSRange(location: 4, length: 4))
        #expect(mention.query == "gen")
        #expect(mention.kind == .channel)

        // One internal space still completes a multi-word channel name…
        let spaced = try #require(MentionDraft(text: "see #design rev").trailingMention())
        #expect(spaced.query == "design rev")
        #expect(spaced.kind == .channel)
        // …two means the author moved on.
        #expect(MentionDraft(text: "see #design  rev").trailingMention() == nil)
        // A bare trigger opens the whole list; a trigger followed by a space does not,
        // so a markdown heading stays a heading.
        #expect(try #require(MentionDraft(text: "#").trailingMention()).query.isEmpty)
        #expect(MentionDraft(text: "# Heading").trailingMention() == nil)
        // `#` mid-word is not a token, exactly as `@` mid-word is not.
        #expect(MentionDraft(text: "written in C#").trailingMention() == nil)
        #expect(MentionDraft(text: "line one\n#gen").trailingMention()?.kind == .channel)
    }

    @Test("the latest trigger wins, so a channel token does not resolve as a person")
    func latestTriggerWins() throws {
        let mention = try #require(MentionDraft(text: "@ada #gen").trailingMention())
        #expect(mention.kind == .channel)
        #expect(mention.query == "gen")

        let reversed = try #require(MentionDraft(text: "#gen @ad").trailingMention())
        #expect(reversed.kind == .user)
        #expect(reversed.query == "ad")
    }

    // MARK: - Insertion

    @Test("insertion styles one identity and backspace removes the whole token")
    func atomicDeletion() throws {
        var draft = MentionDraft(text: "hello @ad")
        let trailing = try #require(draft.trailingMention())
        draft.insert(candidate(), replacing: trailing.range)

        #expect(draft.text == "hello @Ada Lovelace ")
        #expect(draft.tokens.count == 1)
        #expect(draft.tokens.first?.kind == .user)
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "a", count: 64)])
        #expect(draft.trailingMention() == nil)

        let token = try #require(draft.tokens.first)
        let backspaceInside = NSRange(location: NSMaxRange(token.range) - 1, length: 1)
        draft.replaceCharacters(in: backspaceInside, with: "")
        #expect(draft.text == "hello  ")
        #expect(draft.tokens.isEmpty)
    }

    @Test("every kind inserts the label plus exactly one space, caret after the space")
    func insertionShape() throws {
        for suggestion in [candidate(), channel(), channel("design rev", id: "room-2")] {
            var draft = MentionDraft(text: "hey \(suggestion.kind.trigger)x")
            let trailing = try #require(draft.trailingMention())
            let caret = draft.insert(suggestion, replacing: trailing.range)

            let expected = "hey \(suggestion.insertionLabel) "
            #expect(draft.text == expected)
            // Exactly one space, and it is the last character.
            #expect(draft.text.hasSuffix(" "))
            #expect(!draft.text.hasSuffix("  "))
            // The caret is past that space — at the very end of the draft.
            #expect(caret == (expected as NSString).length)
            #expect(draft.preferredCursor == caret)
            // The token covers the label only; the space is deliberately outside it.
            let token = try #require(draft.tokens.first)
            #expect(token.range == NSRange(
                location: 4,
                length: (suggestion.insertionLabel as NSString).length
            ))
            #expect(token.displayName == suggestion.label)
            #expect(token.entityID == suggestion.entityID)
            // The identity is kept in the token list, never in the text.
            #expect(!draft.text.contains(suggestion.entityID))
        }
    }

    @Test("a channel token tags nobody and still deletes atomically")
    func channelTokenDoesNotTag() throws {
        var draft = MentionDraft(text: "ship it in #gen")
        draft.insert(channel(), replacing: try #require(draft.trailingMention()).range)
        draft.replaceCharacters(in: NSRange(location: (draft.text as NSString).length, length: 0), with: "@ad")
        draft.insert(
            candidate(pubkey: String(repeating: "b", count: 64)),
            replacing: try #require(draft.trailingMention()).range
        )

        #expect(draft.text == "ship it in #general @Ada Lovelace ")
        #expect(draft.tokens.map(\.kind) == [.channel, .user])
        // Only the person contributes a `p` tag; the channel id never leaves the draft.
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "b", count: 64)])
        #expect(draft.tokens.first?.pubkey == nil)

        // Backspace at the end of the channel label removes the whole label.
        let channelToken = try #require(draft.tokens.first)
        draft.replaceCharacters(
            in: NSRange(location: NSMaxRange(channelToken.range) - 1, length: 1),
            with: ""
        )
        #expect(draft.text == "ship it in  @Ada Lovelace ")
        #expect(draft.tokens.map(\.kind) == [.user])
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "b", count: 64)])
    }

    @Test("editing before a token shifts its range without losing identity")
    func shiftsToken() throws {
        var draft = MentionDraft(text: "@ad")
        draft.insert(candidate(), replacing: try #require(draft.trailingMention()).range)
        draft.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hi ")
        #expect(draft.tokens.first?.range.location == 3)
        #expect(draft.text == "Hi @Ada Lovelace ")
    }

    @Test("ordinary typing stays native while mention edits remain atomic")
    func editPolicy() throws {
        var draft = MentionDraft(text: "hello @ad")
        draft.insert(candidate(), replacing: try #require(draft.trailingMention()).range)
        let token = try #require(draft.tokens.first)

        #expect(!draft.requiresAtomicEdit(in: NSRange(location: 0, length: 0)))
        #expect(!draft.requiresAtomicEdit(in: NSRange(location: NSMaxRange(token.range), length: 0)))
        #expect(draft.requiresAtomicEdit(in: NSRange(
            location: NSMaxRange(token.range) - 1,
            length: 1
        )))
        #expect(draft.requiresAtomicEdit(in: NSRange(
            location: token.range.location + 1,
            length: 0
        )))

        var systemEdit = draft
        systemEdit.reconcileText("Prefix \(draft.text)")
        #expect(systemEdit.tokens.first?.range.location == token.range.location + 7)
        systemEdit.reconcileText("Prefix hello ")
        #expect(systemEdit.tokens.isEmpty)
    }

    // MARK: - Live index

    @Test("one index completes people for @ and channels for #")
    func completesBothKinds() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let relay = try Fixture()
        let member = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.channelMetadata("room-1", name: "general"),
            try relay.channelMetadata("room-2", name: "design", isPrivate: true),
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

        model.update(for: MentionDraft(text: "hey @ad"))
        await waitUntil { model.suggestions.map(\.label) == ["Ada Lovelace"] }
        #expect(model.suggestions.map(\.kind) == [.user])

        model.update(for: MentionDraft(text: "see #de"))
        await waitUntil { model.suggestions.map(\.label) == ["design"] }
        #expect(model.suggestions.map(\.kind) == [.channel])
        #expect(model.suggestions.first?.insertionLabel == "#design")
        #expect(model.suggestions.first?.isPrivateChannel == true)

        // A bare `#` lists every named channel, in the read's alphabetical order.
        model.update(for: MentionDraft(text: "see #"))
        await waitUntil { model.suggestions.count == 2 }
        #expect(model.suggestions.map(\.label) == ["design", "general"])

        // Picking one inserts through the same path a person goes through.
        var draft = MentionDraft(text: "see #")
        let picked = try #require(model.suggestions.last)
        model.select(picked, in: &draft)
        #expect(draft.text == "see #general ")
        #expect(draft.mentionedPubkeys(sender: nil).isEmpty)
    }

    // MARK: - Send path

    @Test("channel send emits one normalized p tag for the selected mention")
    func sendTagsMention() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = try RecordingSender()
        let me = String(repeating: "f", count: 64)
        let model = ChannelTimelineModel(
            channel: "room-1",
            store: store,
            sender: sender,
            selfPubkey: me
        )
        var draft = MentionDraft(text: "@ad")
        draft.insert(candidate(pubkey: String(repeating: "A", count: 64)), replacing: try #require(
            draft.trailingMention()
        ).range)
        draft.replaceCharacters(in: NSRange(location: (draft.text as NSString).length, length: 0), with: "#gen")
        draft.insert(channel(), replacing: try #require(draft.trailingMention()).range)
        model.mentionDraft = draft

        model.send()
        await waitUntil { await sender.sent.count == 1 }

        let sent = try #require(await sender.sent.first)
        #expect(sent.content == "@Ada Lovelace #general")
        // The channel reference is in the content and nowhere in the tags.
        #expect(sent.tags == [
            ["h", "room-1"],
            ["p", String(repeating: "a", count: 64)],
        ])
    }
}
