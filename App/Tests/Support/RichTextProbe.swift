import Foundation
@testable import Hive

/// Read helpers for asserting over the value AST: block inlines, entity-run
/// attributes, emphasis, and links. Keeps the suites focused on behaviour rather
/// than `AttributedString` plumbing.
enum RichTextProbe {
    /// The inline content of a text-bearing block, empty for code/list blocks.
    static func inline(of block: RichBlock) -> AttributedString {
        switch block {
        case let .paragraph(text), let .quote(text):
            return text
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
            if let link = inline(of: block).runs.compactMap(\.link).first { return link }
        }
        return nil
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
                deepest = max(deepest, maxListDepth(item.children, current: current + 1))
            }
        }
        return deepest
    }
}
