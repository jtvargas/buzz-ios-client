import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The entity pass, the production resolver, and the memo: `@`-mention and
/// `#`-channel token attachment over post-markdown inlines, name resolution from a
/// message's own data, and re-resolution on resolver-identity change. Pure values —
/// no store, no view.
@Suite("Rich text entities")
struct RichTextEntityTests {
    private func resolved(_ text: String, _ resolver: MentionResolver) -> [RichBlock] {
        RichTextEntities.resolve(RichTextParser.parse(text), with: resolver)
    }

    // MARK: - Mentions

    @Test("a resolving @name gains a mention token carrying its pubkey")
    func mentionResolves() {
        let resolver = StubMentionResolver(members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)])
        let inline = RichTextProbe.inline(of: resolved("hey @bob", resolver)[0])
        #expect(RichTextProbe.mentionText(inline) == "@bob")
        #expect(RichTextProbe.firstMention(inline)?.pubkey == "PK_BOB")
        #expect(RichTextProbe.firstMention(inline)?.isSelf == false)
    }

    @Test("a self-mention sets isSelf when the pubkey is the local identity")
    func selfMention() {
        let resolver = StubMentionResolver(
            members: ["bob": MentionMatch(pubkey: "PK_ME", isSelf: true)],
            selfPubkey: "PK_ME"
        )
        let inline = RichTextProbe.inline(of: resolved("ping @bob", resolver)[0])
        #expect(RichTextProbe.firstMention(inline)?.isSelf == true)
        #expect(RichTextProbe.firstMention(inline)?.pubkey == "PK_ME")
    }

    @Test("a mention resolves through overlapping markdown — @**bob**")
    func mentionOverlapsBold() {
        let resolver = StubMentionResolver(members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)])
        let inline = RichTextProbe.inline(of: resolved("yo @**bob** there", resolver)[0])
        #expect(RichTextProbe.mentionText(inline) == "@bob")
        #expect(RichTextProbe.firstMention(inline)?.pubkey == "PK_BOB")
        #expect(RichTextProbe.hasBold(inline))
    }

    @Test("the longest resolving name wins for a multi-word mention")
    func multiWordMention() {
        let resolver = StubMentionResolver(members: [
            "ada lovelace": MentionMatch(pubkey: "PK_FULL", isSelf: false),
            "ada": MentionMatch(pubkey: "PK_SHORT", isSelf: false),
        ])
        let inline = RichTextProbe.inline(of: resolved("hi @ada lovelace!", resolver)[0])
        #expect(RichTextProbe.mentionText(inline) == "@ada lovelace")
        #expect(RichTextProbe.firstMention(inline)?.pubkey == "PK_FULL")
    }

    @Test("an unresolved @word stays plain text")
    func unmatchedMentionPlain() {
        let inline = RichTextProbe.inline(of: resolved("@nobody here", StubMentionResolver())[0])
        #expect(RichTextProbe.mentionRuns(inline).isEmpty)
    }

    @Test("an @ glued to a word (an email) never becomes a mention")
    func emailNotMention() {
        let resolver = StubMentionResolver(members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)])
        let inline = RichTextProbe.inline(of: resolved("mail a@bob today", resolver)[0])
        #expect(RichTextProbe.mentionRuns(inline).isEmpty)
    }

    // MARK: - Channels

    @Test("a resolving #name gains a channel token carrying its id")
    func channelResolves() {
        let resolver = StubMentionResolver(channels: ["general": "CH_GEN"])
        let inline = RichTextProbe.inline(of: resolved("see #general now", resolver)[0])
        #expect(RichTextProbe.channelRuns(inline).first?.text == "#general")
        #expect(RichTextProbe.firstChannel(inline)?.channelID == "CH_GEN")
    }

    @Test("a #channel at the very start of a line still resolves")
    func channelAtLineStart() {
        let resolver = StubMentionResolver(channels: ["general": "CH_GEN"])
        let inline = RichTextProbe.inline(of: resolved("#general is where", resolver)[0])
        #expect(RichTextProbe.firstChannel(inline)?.channelID == "CH_GEN")
        #expect(RichTextProbe.channelRuns(inline).first?.text == "#general")
    }

    @Test("an unresolved #word stays plain text")
    func unmatchedChannelPlain() {
        let inline = RichTextProbe.inline(of: resolved("#unknown place", StubMentionResolver())[0])
        #expect(RichTextProbe.channelRuns(inline).isEmpty)
    }

    // MARK: - Code is never entity-parsed

    @Test("a fenced code block is never entity-parsed")
    func codeFenceNeverEntity() {
        let resolver = StubMentionResolver(members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)])
        let blocks = resolved("```\n@bob and #general\n```", resolver)
        #expect(blocks == [.code("@bob and #general", language: nil)])
    }

    @Test("an inline code span is never entity-parsed")
    func inlineCodeNeverEntity() {
        let resolver = StubMentionResolver(members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)])
        let inline = RichTextProbe.inline(of: resolved("run `@bob` now", resolver)[0])
        #expect(RichTextProbe.mentionRuns(inline).isEmpty)
    }

    // MARK: - Mixed document

    @Test("one message carries a heading mention, a channel, code, bold, and a link")
    func mixedDocumentEntities() {
        let resolver = StubMentionResolver(
            members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)],
            channels: ["general": "CH_GEN"]
        )
        let message = "# Team @bob\nnotes\n\nsee #general and `@bob`"
            + " and **bold** and [x](https://y.com)"
        let blocks = resolved(message, resolver)
        // Heading carries the mention.
        let heading = RichTextProbe.inline(of: blocks[0])
        #expect(RichTextProbe.firstMention(heading)?.pubkey == "PK_BOB")
        // The final paragraph carries the channel, bold, and link — but no mention,
        // because its only @bob is inside inline code.
        guard let paragraph = blocks.last.map(RichTextProbe.inline) else {
            Issue.record("expected a trailing paragraph")
            return
        }
        #expect(RichTextProbe.firstChannel(paragraph)?.channelID == "CH_GEN")
        #expect(RichTextProbe.mentionRuns(paragraph).isEmpty)
        #expect(RichTextProbe.hasBold(paragraph))
        #expect(paragraph.runs.compactMap(\.link).first?.absoluteString == "https://y.com")
    }

    // MARK: - Production resolver

    @Test("the production resolver matches full name and first-name alias, not a surname")
    func productionResolverAliases() {
        let resolver = MessageMentionResolver(
            mentions: [MentionRef(pubkey: "PK_ADA", displayName: "Ada Lovelace")],
            channels: .empty,
            selfPubkey: nil
        )
        #expect(resolver.mention(forName: "Ada Lovelace")?.pubkey == "PK_ADA")
        #expect(resolver.mention(forName: "ada")?.pubkey == "PK_ADA")
        #expect(resolver.mention(forName: "Lovelace") == nil)
    }

    @Test("the production resolver flags a self-mention against the local identity")
    func productionResolverSelf() {
        let resolver = MessageMentionResolver(
            mentions: [MentionRef(pubkey: "PK_ME", displayName: "Me")],
            channels: .empty,
            selfPubkey: "PK_ME"
        )
        #expect(resolver.mention(forName: "Me")?.isSelf == true)
    }

    @Test("a channel-name collision resolves to the first channel")
    func channelMapFirstMatch() {
        let map = ChannelNameMap([(name: "General", id: "CH_1"), (name: "general", id: "CH_2")])
        #expect(map.id(forName: "general") == "CH_1")
    }

    @Test("a display-name change changes the resolver identity")
    func identityChangesOnRename() {
        let before = MessageMentionResolver(
            mentions: [MentionRef(pubkey: "PK", displayName: "Ada")],
            channels: .empty, selfPubkey: nil
        )
        let after = MessageMentionResolver(
            mentions: [MentionRef(pubkey: "PK", displayName: "Ada Lovelace")],
            channels: .empty, selfPubkey: nil
        )
        #expect(before.identity != after.identity)
    }

    // MARK: - Memo

    @MainActor
    @Test("the memo re-resolves when the resolver identity changes")
    func memoReresolvesOnIdentityChange() {
        RichMessageCache.removeAll()
        let text = "hi @bob"
        let known = StubMentionResolver(
            members: ["bob": MentionMatch(pubkey: "PK_BOB", isSelf: false)],
            identity: "known"
        )
        let unknown = StubMentionResolver(identity: "unknown")

        let first = RichMessageCache.message(for: text, resolver: known)
        #expect(RichTextProbe.firstMention(RichTextProbe.inline(of: first.blocks[0]))?.pubkey == "PK_BOB")

        // Same text, different identity: must NOT serve the cached (resolved) copy.
        let second = RichMessageCache.message(for: text, resolver: unknown)
        #expect(RichTextProbe.mentionRuns(RichTextProbe.inline(of: second.blocks[0])).isEmpty)

        // Same text + same identity returns the equal, cached value.
        let third = RichMessageCache.message(for: text, resolver: known)
        #expect(third == first)
    }

    @MainActor
    @Test("the memo key keeps resolver identity and untrusted text structurally separate")
    func memoKeyHasNoDelimiterCollision() {
        RichMessageCache.removeAll()
        let first = RichMessageCache.message(
            for: "\u{1}first",
            resolver: StubMentionResolver(identity: "resolver")
        )
        let second = RichMessageCache.message(
            for: "first",
            resolver: StubMentionResolver(identity: "resolver\u{1}")
        )

        #expect(String(RichTextProbe.inline(of: first.blocks[0]).characters) == "\u{1}first")
        #expect(String(RichTextProbe.inline(of: second.blocks[0]).characters) == "first")
    }
}
