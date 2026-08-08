import BuzzKit
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
indirect enum RichBlock: Equatable, Sendable {
    /// A run of text. Soft line breaks inside it are preserved.
    case paragraph(AttributedString)
    /// A heading, level 1–6.
    case heading(level: Int, AttributedString)
    /// A block quote containing the same block shapes as the document around it.
    case quote([RichBlock])
    /// A fenced code block: raw text (NEVER inline- or entity-parsed) and parsed
    /// language information from the opening fence.
    case code(String, info: CodeFenceInfo?)
    /// A bulleted list; each element is one item, which may own nested lists.
    case bulletList([RichListItem])
    /// A numbered list starting at `start`; each element is one item, which may own
    /// nested lists. `start` is the first item's authored number.
    case orderedList(start: Int, [RichListItem])
    /// A GFM pipe table, cells already split and inline-parsed.
    case table(RichTable)
    /// A thematic break — a rule across the message, from a line of `---`, `***`,
    /// `___`, or the reference renderer's own `⸻`.
    case rule
    /// One blank source line authored between semantic blocks. Runs are bounded by
    /// the parser and leading/trailing source whitespace never produces this case.
    case sourceBlankLine
    /// One or more pictures and videos, drawn together where the message put them.
    ///
    /// # Why a block and not an inline
    ///
    /// The reference renderers place an attachment at the markdown image its author
    /// wrote — `![alt](url)` — and describe it from the `imeta` tag that names the same
    /// URL (see ``RichTextMedia``). Inline in their text flow; a block here, because a
    /// picture in a conversation takes a line of its own at any size a phone offers, and
    /// an inline that always breaks is a block that has to be measured twice.
    ///
    /// The associated value is an array of whole ``MessageMedia`` rather than an array of
    /// URLs on purpose: the renderer needs every declared aspect ratio *before* it asks
    /// for a byte, or the row grows when a picture lands and takes the reader's place in
    /// the conversation with it. A case carrying only URLs would make that impossible to
    /// get right and easy to not notice.
    ///
    /// More than one entry means the author placed consecutive pictures with nothing
    /// between them — see ``RichTextMedia/lift(_:describedBy:)`` — and the renderer draws
    /// them as one mosaic rather than as several attachments in a row. A single entry is
    /// the common case and draws exactly as one attachment always has.
    case media([MessageMedia])
    /// A card for a link the message points at, appended after everything the author
    /// wrote — see ``RichTextLinkPreview``.
    ///
    /// # Why a block and not something the paragraph carries
    ///
    /// A card is not where its link is. The link stays exactly where the author typed it,
    /// still a pressable run in the sentence; the card is a separate object drawn at the
    /// end of the message, the way both reference clients draw theirs and the way an
    /// attachment already behaves here. Modelling it as a block is what lets
    /// ``RichTextSpacing`` reason about the air around it and the memo cache carry it,
    /// with no second render path to keep in step.
    case linkPreview(LinkPreview)
}

/// What a list item draws in place of its list's own bullet or number.
///
/// A property of the *item*, not of the list, and that is the whole reason it exists
/// here rather than as a third list case on ``RichBlock``: `- [ ] done` and `- plain`
/// are one authored list, and splitting it into a task block and a bullet block would
/// break it in two on screen at the exact point the author was mid-thought.
enum RichListMarker: Equatable, Sendable {
    /// A GFM task item, `- [ ] todo` / `- [x] done`, or the reference renderer's bare
    /// `[ ] todo`. The associated value is whether it is ticked.
    case checkbox(Bool)
    /// The reference renderer's bare `( ) one` / `(x) one`. Not CommonMark, not GFM —
    /// carried because upstream draws it and a message written against upstream must
    /// not read as literal punctuation here.
    case radio(Bool)
}

/// One item of a list: an optional marker that replaces the list's bullet or number,
/// and the full block content authored beneath it.
struct RichListItem: Equatable, Sendable {
    /// Paragraphs, quotes, code, tables, or nested lists contained by this item.
    let blocks: [RichBlock]
    /// A checkbox or radio marker drawn instead of the list's own marker, or `nil` for
    /// an ordinary item. See ``RichListMarker``.
    let marker: RichListMarker?
    init(blocks: [RichBlock], marker: RichListMarker? = nil) {
        self.blocks = blocks
        self.marker = marker
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

extension [RichBlock] {
    /// Applies `transform` to every inline in the tree, recursing into nested list
    /// items and leaving code blocks untouched.
    ///
    /// The walk the post-markdown passes share — autolinking and entity resolution
    /// visit exactly the same inlines for exactly the same reason (a fenced code
    /// block is raw text and an inline is a parsed `AttributedString`), and a second
    /// copy of it is a second place for the two to disagree about where a list item's
    /// children live.
    func mapInlines(_ transform: (AttributedString) -> AttributedString) -> [RichBlock] {
        map { block in
            switch block {
            case let .paragraph(text):
                .paragraph(transform(text))
            case let .heading(level, text):
                .heading(level: level, transform(text))
            case let .quote(blocks):
                .quote(blocks.mapInlines(transform))
            case .code:
                block // code is never inline-parsed
            case let .bulletList(items):
                .bulletList(items.map { $0.mapInlines(transform) })
            case let .orderedList(start, items):
                .orderedList(start: start, items.map { $0.mapInlines(transform) })
            case let .table(table):
                .table(table.mapCells(transform))
            case .rule, .sourceBlankLine, .linkPreview, .media:
                // These blocks carry no authored inline to transform.
                block
            }
        }
    }
}

extension RichListItem {
    /// This item with `transform` applied recursively to every inline it contains.
    func mapInlines(_ transform: (AttributedString) -> AttributedString) -> RichListItem {
        RichListItem(
            blocks: blocks.mapInlines(transform),
            marker: marker
        )
    }
}
