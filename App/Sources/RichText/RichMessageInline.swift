import BuzzKit
import Foundation

extension RichMessage {
    /// A single-line flattening of the whole message: every block's inline content
    /// joined with spaces, entity attributes preserved, code rendered as its raw
    /// text. Backs the snippet render mode (previews, channel-list) so a one-line
    /// preview still tints mentions and channels exactly like the full render.
    func flattenedInline() -> AttributedString {
        var result = AttributedString()
        for block in blocks {
            let piece = Self.inline(of: block)
            guard !piece.characters.isEmpty else { continue }
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(piece)
        }
        return result
    }

    private static func inline(of block: RichBlock) -> AttributedString {
        switch block {
        case let .paragraph(text):
            return text
        case let .quote(blocks):
            return joined(blocks.map { inline(of: $0) })
        case let .heading(_, text):
            return text
        case let .code(code, _):
            return AttributedString(code)
        case let .bulletList(items):
            return inline(of: items)
        case let .orderedList(_, items):
            return inline(of: items)
        case let .table(table):
            return joined(table.cellsInReadingOrder)
        case .rule, .sourceBlankLine:
            // A rule is a shape, not words. Flattening it to punctuation would put a
            // stray `—` in a sidebar preview where the message's own first sentence
            // belongs.
            return AttributedString()
        case let .media(items):
            return AttributedString(noun(for: items))
        case .linkPreview:
            // Nothing, and for the opposite reason to a picture's. A card is a *second*
            // rendering of a link whose text is still in the message, so the snippet
            // already has it; adding the card's title would print the same link twice in
            // the one truncated line a sidebar row gets.
            return AttributedString()
        }
    }

    /// What a group of pictures contributes to a one-line preview: the count and the word
    /// for what they are.
    ///
    /// Not nothing, the way a rule contributes nothing: a rule is decoration, but a
    /// message that is only a photograph is *entirely* its attachment, and flattening it
    /// away leaves a preview that is blank where the message is not. Saying "Image" is
    /// the least a reader needs to know something arrived, and a group says how many —
    /// "3 Images" is a different message from one, and a snippet that read the same for
    /// both would be losing information the full render shows plainly.
    ///
    /// Not the author's alt either, though it is right there on the media. An alt is
    /// written to be read *instead of* the picture and runs as long as it needs to; a
    /// snippet is one truncated line already competing with the words the author typed,
    /// and a paragraph-long description of a screenshot would push those words off the
    /// end of it. The alt keeps its own job on the full render and in VoiceOver.
    private static func noun(for items: [MessageMedia]) -> String {
        guard let first = items.first else { return "" }
        guard items.count > 1 else { return singularNoun(for: first.kind) }
        return "\(items.count) \(singularNoun(for: first.kind))s"
    }

    private static func singularNoun(for kind: MessageMediaKind) -> String {
        switch kind {
        case .image: "Image"
        case .video: "Video"
        case .file: "File"
        }
    }

    /// `pieces` concatenated with a single space between the non-empty ones.
    private static func joined(_ pieces: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for piece in pieces where !piece.characters.isEmpty {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(piece)
        }
        return result
    }

    private static func inline(of items: [RichListItem]) -> AttributedString {
        var result = AttributedString()
        for item in items {
            let piece = joined(item.blocks.map { inline(of: $0) })
            guard !piece.characters.isEmpty else { continue }
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(piece)
        }
        return result
    }
}
