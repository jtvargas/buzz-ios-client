import BuzzKit
@testable import Hive
import Foundation
import Testing

@MainActor
@Suite("Mention composer", .timeLimit(.minutes(1)))
struct MentionComposerTests {
    private func candidate(
        _ name: String = "Ada Lovelace",
        pubkey: String = String(repeating: "a", count: 64)
    ) -> MentionCandidateProfile {
        MentionCandidateProfile(
            pubkey: pubkey,
            displayName: name,
            isAgent: false,
            isChannelMember: true
        )
    }

    @Test("detects a trailing mention without treating an email as one")
    func trailingToken() throws {
        let mention = try #require(MentionDraft(text: "hello @ad").trailingMention())
        #expect(mention.range == NSRange(location: 6, length: 3))
        #expect(mention.query == "ad")
        #expect(MentionDraft(text: "mail@test").trailingMention() == nil)
        #expect(MentionDraft(text: "done @ada  next").trailingMention() == nil)
    }

    @Test("insertion styles one identity and backspace removes the whole token")
    func atomicDeletion() throws {
        var draft = MentionDraft(text: "hello @ad")
        let trailing = try #require(draft.trailingMention())
        draft.insert(candidate(), replacing: trailing.range)

        #expect(draft.text == "hello @Ada Lovelace ")
        #expect(draft.tokens.count == 1)
        #expect(draft.mentionedPubkeys(sender: nil) == [String(repeating: "a", count: 64)])
        #expect(draft.trailingMention() == nil)

        let token = try #require(draft.tokens.first)
        let backspaceInside = NSRange(location: NSMaxRange(token.range) - 1, length: 1)
        draft.replaceCharacters(in: backspaceInside, with: "")
        #expect(draft.text == "hello  ")
        #expect(draft.tokens.isEmpty)
    }

    @Test("editing before a token shifts its range without losing identity")
    func shiftsToken() throws {
        var draft = MentionDraft(text: "@ad")
        draft.insert(candidate(), replacing: try #require(draft.trailingMention()).range)
        draft.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Hi ")
        #expect(draft.tokens.first?.range.location == 3)
        #expect(draft.text == "Hi @Ada Lovelace ")
    }

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
        model.mentionDraft = draft

        model.send()
        await waitUntil { await sender.sent.count == 1 }

        let sent = try #require(await sender.sent.first)
        #expect(sent.content == "@Ada Lovelace")
        #expect(sent.tags == [
            ["h", "room-1"],
            ["p", String(repeating: "a", count: 64)],
        ])
    }
}
