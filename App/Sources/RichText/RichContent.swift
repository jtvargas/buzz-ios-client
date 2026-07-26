import Foundation

/// One block of rendered message content — the unit the renderer lays out on its
/// own line(s). Kind-40002 rich content is CommonMark markdown (the upstream editor
/// serialises its document with `getMarkdown()`), and plain kind-9 content is parsed
/// through the same pipeline so *every* surface renders one message identically.
///
/// Inline emphasis inside a block (bold, italic, code spans, links) plus resolved
/// `@`-mention / `#`-channel tokens are carried in each block's `AttributedString`
/// — parsed inline-only, with unsafe link schemes stripped and entities attached
/// as ``MentionAttribute`` / ``ChannelAttribute`` runs (see ``RichTextEntities``).
enum RichBlock: Equatable, Sendable {
    /// A run of text. Soft line breaks inside it are preserved.
    case paragraph(AttributedString)
    /// A heading, level 1–6.
    case heading(level: Int, AttributedString)
    /// A block quote, its lines joined.
    case quote(AttributedString)
    /// A fenced code block: raw text (NEVER inline- or entity-parsed) and an
    /// optional language hint from the opening fence.
    case code(String, language: String?)
    /// A bulleted list; each element is one item, which may own nested lists.
    case bulletList([RichListItem])
    /// A numbered list starting at `start`; each element is one item, which may own
    /// nested lists. `start` is the first item's authored number.
    case orderedList(start: Int, [RichListItem])
}

/// One item of a list: its own inline content and any nested lists indented beneath
/// it. The `children` are themselves ``RichBlock`` list nodes, so an item can carry
/// arbitrarily deep (bounded) sub-lists that the renderer indents per depth.
struct RichListItem: Equatable, Sendable {
    /// The item's inline content (emphasis, links, resolved entity tokens).
    let content: AttributedString
    /// Nested list blocks indented under this item, empty for a leaf item.
    let children: [RichBlock]

    init(content: AttributedString, children: [RichBlock] = []) {
        self.content = content
        self.children = children
    }
}

/// A fully parsed and entity-resolved message: the value the renderer consumes and
/// the memo caches. The single source of truth every surface (timeline, thread,
/// preview, and later snippet/search/pinned) renders through, so a message never
/// changes appearance by location.
struct RichMessage: Equatable, Sendable {
    let blocks: [RichBlock]

    init(blocks: [RichBlock]) {
        self.blocks = blocks
    }

    static let empty = RichMessage(blocks: [])

    var isEmpty: Bool { blocks.isEmpty }
}
