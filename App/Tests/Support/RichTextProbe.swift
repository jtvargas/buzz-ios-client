import Foundation
@testable import Hive

/// Read helpers for asserting over the value AST: block inlines, entity-run
/// attributes, emphasis, and links. Keeps the suites focused on behaviour rather
/// than `AttributedString` plumbing.
enum RichTextProbe {
    /// The inline content of a text-bearing block, empty for code/list blocks.
    static func inline(of block: RichBlock) -> AttributedString {
        switch block {
        case let .paragraph(text):
            return text
        case let .quote(blocks):
            return joined(blocks.map(inline(of:)))
        case let .heading(_, text):
            return text
        default:
            return AttributedString()
        }
    }

    /// Every run carrying a mention token, as `(visibleText, token)`.
    static func mentionRuns(_ attributed: AttributedString) -> [(text: String, token: MentionToken)] {
        attributed.runs.compactMap { run in
            run.mention.map { (String(attributed[run.range].characters), $0) }
        }
    }

    /// Every run carrying a channel token, as `(visibleText, token)`.
    static func channelRuns(_ attributed: AttributedString) -> [(text: String, token: ChannelToken)] {
        attributed.runs.compactMap { run in
            run.channel.map { (String(attributed[run.range].characters), $0) }
        }
    }

    /// The full visible text of the mention (joined across runs, e.g. when part is
    /// also bold), or `nil` when there is no mention.
    static func mentionText(_ attributed: AttributedString) -> String? {
        let runs = mentionRuns(attributed)
        return runs.isEmpty ? nil : runs.map(\.text).joined()
    }

    static func firstMention(_ attributed: AttributedString) -> MentionToken? {
        attributed.runs.compactMap(\.mention).first
    }

    static func firstChannel(_ attributed: AttributedString) -> ChannelToken? {
        attributed.runs.compactMap(\.channel).first
    }

    /// Whether any run is strongly emphasised (bold).
    static func hasBold(_ attributed: AttributedString) -> Bool {
        attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
    }

    /// The first tappable link across all text blocks, or `nil`.
    static func firstLink(_ blocks: [RichBlock]) -> URL? {
        for block in blocks {
            if let link = links(in: block).first { return link }
        }
        return nil
    }

    static func inline(of item: RichListItem) -> AttributedString {
        joined(item.blocks.map(inline(of:)))
    }

    /// The deepest list nesting in `blocks` (0 when there are no lists), for the
    /// depth-clamp assertion.
    static func maxListDepth(_ blocks: [RichBlock], current: Int = 0) -> Int {
        var deepest = current
        for block in blocks {
            let items: [RichListItem]
            switch block {
            case let .bulletList(list): items = list
            case let .orderedList(_, list): items = list
            default: continue
            }
            deepest = max(deepest, current + 1)
            for item in items {
                deepest = max(deepest, maxListDepth(item.blocks, current: current + 1))
            }
        }
        return deepest
    }

    private static func links(in block: RichBlock) -> [URL] {
        switch block {
        case let .paragraph(text), let .heading(_, text):
            text.runs.compactMap(\.link)
        case let .quote(blocks):
            blocks.flatMap(links(in:))
        case let .bulletList(items), let .orderedList(_, items):
            items.flatMap { $0.blocks.flatMap(links(in:)) }
        case let .table(table):
            table.cellsInReadingOrder.flatMap { $0.runs.compactMap(\.link) }
        default:
            []
        }
    }

    private static func joined(_ pieces: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for piece in pieces where !piece.characters.isEmpty {
            if !result.characters.isEmpty { result.append(AttributedString(" ")) }
            result.append(piece)
        }
        return result
    }
}
