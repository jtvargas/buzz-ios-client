import Foundation
import Markdown

/// Converts swift-markdown's CommonMark + GFM tree into Hive's renderer-neutral
/// ``RichBlock`` tree.
struct RichTextMarkdownWalker {
    private let sourceLines: [String]
    private let document: Document

    init(_ markdown: String) {
        let normalized = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        sourceLines = normalized.components(separatedBy: "\n")
        document = Document(parsing: normalized, options: [.disableSmartOpts])
    }

    var blocks: [RichBlock] {
        blocks(from: document.children, listDepth: 0)
    }

    // MARK: - Blocks

    private func blocks<Children: Sequence>(
        from children: Children,
        listDepth: Int
    ) -> [RichBlock] where Children.Element == Markup {
        var result: [RichBlock] = []
        var hasPreviousBlock = false

        for child in children {
            let converted = block(child, listDepth: listDepth)
            guard !converted.isEmpty else { continue }
            let blankLineCount: Int
            if hasPreviousBlock {
                let authored = min(precedingBlankLineCount(for: child), RichTextParser.maxBlankLineRun)
                blankLineCount = max(0, authored - 1)
                result.append(contentsOf: repeatElement(.sourceBlankLine, count: blankLineCount))
            } else {
                blankLineCount = 0
            }
            append(converted, to: &result, mayMergeList: hasPreviousBlock && blankLineCount == 0)
            hasPreviousBlock = true
        }
        return result
    }

    /// cmark splits lists when their authored bullet or ordered delimiter changes.
    /// Hive's value model does not preserve delimiter style, so keep the scanner-era
    /// behavior and coalesce adjacent same-kind lists when no blank line separates them.
    private func append(_ blocks: [RichBlock], to result: inout [RichBlock], mayMergeList: Bool) {
        guard mayMergeList, blocks.count == 1, let incoming = blocks.first, let previous = result.last else {
            result.append(contentsOf: blocks)
            return
        }
        switch (previous, incoming) {
        case let (.bulletList(left), .bulletList(right)):
            result[result.count - 1] = .bulletList(left + right)
        case let (.orderedList(start, left), .orderedList(_, right)):
            result[result.count - 1] = .orderedList(start: start, left + right)
        default:
            result.append(incoming)
        }
    }

    private func block(_ markup: Markup, listDepth: Int) -> [RichBlock] {
        switch markup {
        case let paragraph as Paragraph:
            let inline = inlineChildren(of: paragraph)
            let visible = String(inline.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            if RichTextParser.isThematicBreak(visible) { return [.rule] }
            return promotedBareMarkers(in: inline)
        case let heading as Heading:
            return [.heading(level: heading.level, inlineChildren(of: heading))]
        case let quote as BlockQuote:
            return [.quote(blocks(from: quote.children, listDepth: listDepth))]
        case let code as CodeBlock:
            return [.code(code.code, info: CodeFenceInfo(rawInfoString: code.language))]
        case let list as UnorderedList:
            return [.bulletList(listItems(in: list, depth: listDepth))]
        case let list as OrderedList:
            let start = Int(clamping: list.startIndex)
            return [.orderedList(start: start, listItems(in: list, depth: listDepth))]
        case let table as Markdown.Table:
            return [tableBlock(table)]
        case is ThematicBreak:
            return [.rule]
        case let html as HTMLBlock:
            return [.paragraph(AttributedString(html.rawHTML))]
        default:
            let fallback = sourceText(for: markup)
            return fallback.isEmpty ? [] : [.paragraph(AttributedString(fallback))]
        }
    }

    /// CommonMark discards blank lines between blocks. Source positions stay enabled,
    /// so recover only source lines that are actually empty. The caller removes the one
    /// separator CommonMark already represents through semantic pair spacing. Leading
    /// and trailing whitespace have no adjacent pair and cannot produce a spacer.
    private func precedingBlankLineCount(for markup: Markup) -> Int {
        guard let line = markup.range?.lowerBound.line else { return 0 }
        var index = line - 2
        var count = 0
        while index >= 0,
              index < sourceLines.count,
              sourceLines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            count += 1
            index -= 1
        }
        return count
    }

    // MARK: - Lists

    private func listItems<List: ListItemContainer>(in list: List, depth: Int) -> [RichListItem] {
        guard depth >= RichTextParser.maxListDepth else {
            return list.listItems.map { item in
                RichListItem(
                    blocks: blocks(from: item.children, listDepth: depth + 1),
                    marker: marker(for: item)
                )
            }
        }
        return flattenedListItems(in: list)
    }

    /// At the depth cap, walk any deeper list nodes iteratively and append their items
    /// to the deepest materialised list. No authored item is dropped, and pathological
    /// indentation cannot deepen either the value tree or this conversion's call stack.
    private func flattenedListItems<List: ListItemContainer>(in list: List) -> [RichListItem] {
        var pending = Array(list.listItems.reversed())
        var result: [RichListItem] = []

        while let item = pending.popLast() {
            var ownBlocks: [Markup] = []
            var nestedItems: [ListItem] = []
            for child in item.children {
                if let nested = child as? UnorderedList {
                    nestedItems.append(contentsOf: nested.listItems)
                } else if let nested = child as? OrderedList {
                    nestedItems.append(contentsOf: nested.listItems)
                } else {
                    ownBlocks.append(child)
                }
            }
            result.append(RichListItem(
                blocks: blocks(from: ownBlocks, listDepth: RichTextParser.maxListDepth),
                marker: marker(for: item)
            ))
            pending.append(contentsOf: nestedItems.reversed())
        }
        return result
    }

    private func marker(for item: ListItem) -> RichListMarker? {
        switch item.checkbox {
        case .checked: .checkbox(true)
        case .unchecked: .checkbox(false)
        case nil: nil
        }
    }

    // MARK: - Bare task markers

    /// The upstream-only bare checkbox/radio syntax is inline text to CommonMark.
    /// Split a soft-broken paragraph into authored lines, promote exact marker lines,
    /// and group consecutive promoted lines back into one list.
    private func promotedBareMarkers(in inline: AttributedString) -> [RichBlock] {
        let lines = splitLines(inline)
        guard lines.contains(where: { bareMarker(in: $0) != nil }) else { return [.paragraph(inline)] }

        var result: [RichBlock] = []
        var paragraphLines: [AttributedString] = []
        var listItems: [RichListItem] = []

        func flushParagraph() {
            guard !paragraphLines.isEmpty else { return }
            result.append(.paragraph(joinedLines(paragraphLines)))
            paragraphLines.removeAll(keepingCapacity: true)
        }
        func flushList() {
            guard !listItems.isEmpty else { return }
            result.append(.bulletList(listItems))
            listItems.removeAll(keepingCapacity: true)
        }

        for line in lines {
            if let promoted = bareMarker(in: line) {
                flushParagraph()
                listItems.append(promoted)
            } else {
                flushList()
                paragraphLines.append(line)
            }
        }
        flushParagraph()
        flushList()
        return result
    }

    private func bareMarker(in line: AttributedString) -> RichListItem? {
        let value = String(line.characters)
        let matches: [(String, RichListMarker)] = [
            ("[ ] ", .checkbox(false)),
            ("[x] ", .checkbox(true)),
            ("[X] ", .checkbox(true)),
            ("( ) ", .radio(false)),
            ("(x) ", .radio(true)),
            ("(X) ", .radio(true))
        ]
        guard let (prefix, marker) = matches.first(where: { value.hasPrefix($0.0) }) else { return nil }
        let start = line.characters.index(line.startIndex, offsetBy: prefix.count)
        let content = AttributedString(line[start ..< line.endIndex])
        return RichListItem(blocks: [.paragraph(content)], marker: marker)
    }

    private func splitLines(_ inline: AttributedString) -> [AttributedString] {
        var result: [AttributedString] = []
        var start = inline.startIndex
        var cursor = inline.startIndex
        while cursor < inline.endIndex {
            if inline.characters[cursor] == "\n" {
                result.append(AttributedString(inline[start ..< cursor]))
                cursor = inline.characters.index(after: cursor)
                start = cursor
            } else {
                cursor = inline.characters.index(after: cursor)
            }
        }
        result.append(AttributedString(inline[start ..< inline.endIndex]))
        return result
    }

    private func joinedLines(_ lines: [AttributedString]) -> AttributedString {
        var result = AttributedString()
        for line in lines {
            if !result.characters.isEmpty { result.append(AttributedString("\n")) }
            result.append(line)
        }
        return result
    }

    // MARK: - Tables

    /// The AST decides that this is a table. Its source range supplies the cells so
    /// Hive can preserve wider body rows that GFM intentionally discards.
    private func tableBlock(_ table: Markdown.Table) -> RichBlock {
        let lines = sourceLines(for: table)
        guard lines.count >= 2,
              let headerSource = RichTextParser.tableCells(lines[0]),
              let alignments = RichTextParser.tableAlignments(lines[1])
        else {
            return .paragraph(AttributedString(lines.joined(separator: "\n")))
        }
        let rowSources = lines.dropFirst(2).compactMap(RichTextParser.tableCells)
        let width = max(alignments.count, max(headerSource.count, rowSources.map(\.count).max() ?? 0))
        guard width * (rowSources.count + 1) <= RichTextParser.maxTableCells else {
            return .paragraph(AttributedString(lines.joined(separator: "\n")))
        }
        return .table(RichTable(
            alignments: alignments,
            header: headerSource.map(inlineFragment),
            rows: rowSources.map { $0.map(inlineFragment) }
        ))
    }

    private func inlineFragment(_ markdown: String) -> AttributedString {
        let fragment = Document(parsing: markdown, options: [.disableSmartOpts])
        guard let container = fragment.children.first else { return AttributedString(markdown) }
        return inlineChildren(of: container)
    }

    // MARK: - Inline AST

    private func inlineChildren(of markup: Markup) -> AttributedString {
        var builder = RichTextInlineBuilder()
        builder.appendChildren(of: markup)
        return builder.result
    }

    // MARK: - Source ranges

    private func sourceLines(for markup: Markup) -> [String] {
        guard let range = markup.range else { return [] }
        let lower = max(0, range.lowerBound.line - 1)
        let inclusiveUpper = range.upperBound.column == 1 && range.upperBound.line > range.lowerBound.line
            ? range.upperBound.line - 1
            : range.upperBound.line
        let upper = min(sourceLines.count - 1, inclusiveUpper - 1)
        guard lower <= upper, lower < sourceLines.count else { return [] }
        let offset = max(0, range.lowerBound.column - 1)
        return sourceLines[lower ... upper].map { line in
            String(line.dropFirst(min(offset, line.count)))
        }
    }

    private func sourceText(for markup: Markup) -> String {
        sourceLines(for: markup).joined(separator: "\n")
    }
}

/// Builds Foundation attributed inlines directly from the same AST as the block
/// layer. Presentation intents are the contract consumed by ``RichTextStyle`` and
/// ``RichTextInline``; image URL attributes are the contract consumed by
/// ``RichTextMedia``.
private struct RichTextInlineBuilder {
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    private(set) var result = AttributedString()
    private var underlineOpen = false

    mutating func appendChildren(
        of markup: Markup,
        intent: InlinePresentationIntent = [],
        link: URL? = nil
    ) {
        for child in markup.children {
            append(child, intent: intent, link: link)
        }
    }

    private mutating func append(
        _ markup: Markup,
        intent: InlinePresentationIntent,
        link: URL?
    ) {
        switch markup {
        case let text as Markdown.Text:
            appendText(text.string, intent: intent, link: link)
        case let code as InlineCode:
            appendText(code.code, intent: intent.union(.code), link: link)
        case let emphasis as Emphasis:
            appendChildren(of: emphasis, intent: intent.union(.emphasized), link: link)
        case let strong as Strong:
            appendChildren(of: strong, intent: intent.union(.stronglyEmphasized), link: link)
        case let strikethrough as Strikethrough:
            appendChildren(of: strikethrough, intent: intent.union(.strikethrough), link: link)
        case let authoredLink as Markdown.Link:
            let target = authoredLink.destination.flatMap(URL.init(string:)).flatMap { url -> URL? in
                guard let scheme = url.scheme?.lowercased(), Self.allowedLinkSchemes.contains(scheme) else {
                    return nil
                }
                return url
            }
            appendChildren(of: authoredLink, intent: intent, link: target)
        case let image as Markdown.Image:
            appendImage(image, intent: intent)
        case let html as InlineHTML:
            appendHTML(html.rawHTML, intent: intent, link: link)
        case is SoftBreak, is LineBreak:
            appendText("\n", intent: intent, link: link)
        default:
            appendChildren(of: markup, intent: intent, link: link)
        }
    }

    private mutating func appendText(
        _ text: String,
        intent: InlinePresentationIntent,
        link: URL?
    ) {
        guard !text.isEmpty else { return }
        var piece = AttributedString(text)
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if let link { piece.link = link }
        if underlineOpen { piece.underline = true }
        result.append(piece)
    }

    private mutating func appendImage(_ image: Markdown.Image, intent: InlinePresentationIntent) {
        guard let source = image.source, let url = URL(string: source) else {
            appendChildren(of: image, intent: intent)
            return
        }
        let alt = plainText(of: image)
        var piece = AttributedString(alt.isEmpty ? "\u{FFFC}" : alt)
        piece.imageURL = url
        if !intent.isEmpty { piece.inlinePresentationIntent = intent }
        if underlineOpen { piece.underline = true }
        result.append(piece)
    }

    private mutating func appendHTML(
        _ raw: String,
        intent: InlinePresentationIntent,
        link: URL?
    ) {
        switch raw.lowercased() {
        case "<u>" where !underlineOpen:
            underlineOpen = true
        case "</u>" where underlineOpen:
            underlineOpen = false
        default:
            appendText(raw, intent: intent, link: link)
        }
    }

    private func plainText(of markup: Markup) -> String {
        markup.children.map { child in
            switch child {
            case let text as Markdown.Text: text.string
            case let code as InlineCode: code.code
            case is SoftBreak, is LineBreak: "\n"
            default: plainText(of: child)
            }
        }.joined()
    }
}
