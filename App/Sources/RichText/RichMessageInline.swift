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
        case let .paragraph(text), let .quote(text):
            return text
        case let .heading(_, text):
            return text
        case let .code(code, _):
            return AttributedString(code)
        case let .bulletList(items):
            return inline(of: items)
        case let .orderedList(_, items):
            return inline(of: items)
        }
    }

    private static func inline(of items: [RichListItem]) -> AttributedString {
        var result = AttributedString()
        for item in items {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(item.content)
            for child in item.children {
                let childInline = inline(of: child)
                guard !childInline.characters.isEmpty else { continue }
                result.append(AttributedString(" "))
                result.append(childInline)
            }
        }
        return result
    }
}
