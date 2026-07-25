import Foundation

/// The entity pass: a pure transform run AFTER the markdown/link stage that attaches
/// ``MentionAttribute`` to resolving `@`-runs and ``ChannelAttribute`` to resolving
/// `#`-runs, over each block's already-parsed `AttributedString`.
///
/// Scanning the *post-markdown* character view (not the raw text) is what lets a
/// mention survive emphasis: `@**bob**` arrives here as the plain characters `@bob`,
/// so the token resolves and the mention range simply overlaps the bold run. Code —
/// both fenced blocks (never converted to an `AttributedString`) and inline code
/// spans — is never entity-parsed. Unresolved `@word` / `#word` stays plain text.
enum RichTextEntities {
    /// The most words an `@`-mention name may span. Bounds the per-`@` resolver
    /// probing so a long line of words is never quadratic.
    private static let maxMentionWords = 6

    // MARK: - Block walk

    /// Resolves entities across every inline in `blocks`, recursing into nested list
    /// items. Code blocks pass through untouched.
    static func resolve(_ blocks: [RichBlock], with resolver: MentionResolver) -> [RichBlock] {
        blocks.map { resolve($0, resolver) }
    }

    private static func resolve(_ block: RichBlock, _ resolver: MentionResolver) -> RichBlock {
        switch block {
        case let .paragraph(text):
            return .paragraph(apply(text, resolver))
        case let .heading(level, text):
            return .heading(level: level, apply(text, resolver))
        case let .quote(text):
            return .quote(apply(text, resolver))
        case .code:
            return block // code is never entity-parsed
        case let .bulletList(items):
            return .bulletList(items.map { resolveItem($0, resolver) })
        case let .orderedList(start, items):
            return .orderedList(start: start, items.map { resolveItem($0, resolver) })
        }
    }

    private static func resolveItem(_ item: RichListItem, _ resolver: MentionResolver) -> RichListItem {
        RichListItem(
            content: apply(item.content, resolver),
            children: item.children.map { resolve($0, resolver) }
        )
    }

    // MARK: - Inline scan

    /// Attaches entity attributes to one inline's resolving `@`/`#` runs. Matches are
    /// collected read-only over the character view first, then applied — attribute
    /// mutation preserves indices, so every collected range stays valid.
    static func apply(_ input: AttributedString, _ resolver: MentionResolver) -> AttributedString {
        var output = input
        let characters = output.characters

        let codeRanges = output.runs
            .filter { $0.inlinePresentationIntent?.contains(.code) == true }
            .map(\.range)
        func inCode(_ index: AttributedString.Index) -> Bool {
            codeRanges.contains { $0.contains(index) }
        }

        var mentions: [(Range<AttributedString.Index>, MentionToken)] = []
        var channels: [(Range<AttributedString.Index>, ChannelToken)] = []

        var cursor = characters.startIndex
        while cursor < characters.endIndex {
            let char = characters[cursor]
            if char == "@" || char == "#", leadingBoundaryOK(characters, at: cursor), !inCode(cursor) {
                if char == "@", let hit = scanMention(characters, from: cursor, resolver) {
                    mentions.append((hit.range, hit.token))
                    cursor = hit.range.upperBound
                    continue
                }
                if char == "#", let hit = scanChannel(characters, from: cursor, resolver) {
                    channels.append((hit.range, hit.token))
                    cursor = hit.range.upperBound
                    continue
                }
            }
            cursor = characters.index(after: cursor)
        }

        for (range, token) in mentions { output[range].mention = token }
        for (range, token) in channels { output[range].channel = token }
        return output
    }

    // MARK: - Token scanners

    /// Scans an `@`-mention at `at`, trying the longest resolving name span first so
    /// `@Ada Lovelace` wins over `@Ada` when both resolve.
    private static func scanMention(
        _ chars: AttributedString.CharacterView,
        from at: AttributedString.Index,
        _ resolver: MentionResolver
    ) -> (range: Range<AttributedString.Index>, token: MentionToken)? {
        let nameStart = chars.index(after: at)
        guard nameStart < chars.endIndex, isWordChar(chars[nameStart]) else { return nil }

        // Gather up to `maxMentionWords` words separated by a single space.
        var wordEnds: [AttributedString.Index] = []
        var cursor = nameStart
        while wordEnds.count < maxMentionWords {
            while cursor < chars.endIndex, isWordChar(chars[cursor]) { cursor = chars.index(after: cursor) }
            wordEnds.append(cursor)
            guard cursor < chars.endIndex, chars[cursor] == " " else { break }
            let afterSpace = chars.index(after: cursor)
            guard afterSpace < chars.endIndex, isWordChar(chars[afterSpace]) else { break }
            cursor = afterSpace
        }

        for count in stride(from: wordEnds.count, through: 1, by: -1) {
            let end = wordEnds[count - 1]
            let name = String(chars[nameStart ..< end])
            if let match = resolver.mention(forName: name) {
                return (at ..< end, MentionToken(pubkey: match.pubkey, isSelf: match.isSelf))
            }
        }
        return nil
    }

    /// Scans a `#`-channel at `at`: a single token that starts with a word character
    /// and may include hyphens (channel ids are slug-like).
    private static func scanChannel(
        _ chars: AttributedString.CharacterView,
        from at: AttributedString.Index,
        _ resolver: MentionResolver
    ) -> (range: Range<AttributedString.Index>, token: ChannelToken)? {
        let nameStart = chars.index(after: at)
        guard nameStart < chars.endIndex, isWordChar(chars[nameStart]) else { return nil }

        var cursor = nameStart
        while cursor < chars.endIndex, isChannelChar(chars[cursor]) { cursor = chars.index(after: cursor) }
        let name = String(chars[nameStart ..< cursor])
        guard let id = resolver.channel(forName: name) else { return nil }
        return (at ..< cursor, ChannelToken(channelID: id))
    }

    // MARK: - Character classes

    /// A token may not open when the prefix is glued to a word or path/URL punctuation
    /// (`@`, `#` inside `foo@bar`, `a/#b`, `x.#y`, …), matching upstream's
    /// `(?<![\w./:-])` boundary — so emails and paths never light up as entities.
    private static func leadingBoundaryOK(
        _ chars: AttributedString.CharacterView,
        at index: AttributedString.Index
    ) -> Bool {
        guard index > chars.startIndex else { return true }
        let prior = chars[chars.index(before: index)]
        if isWordChar(prior) { return false }
        return !(prior == "." || prior == "/" || prior == ":" || prior == "-")
    }

    private static func isWordChar(_ char: Character) -> Bool {
        char == "_" || char.isLetter || char.isNumber
    }

    private static func isChannelChar(_ char: Character) -> Bool {
        char == "-" || isWordChar(char)
    }
}
