import Foundation

/// Parses message markdown into the typed blocks shared by every renderer and
/// downstream rich-text pass.
enum RichTextParser {
    /// The deepest nested list level materialised from untrusted input. The root
    /// list is level zero; deeper authored levels collapse into level eight.
    static let maxListDepth = 8
    /// The deepest nested blockquote level accepted from untrusted input, matching
    /// ``maxListDepth`` because it answers the same question. Excess markers are
    /// dropped by ``clampingQuoteDepth(_:limit:)`` before anything parses the source.
    static let maxQuoteDepth = 8
    /// The most authored blank lines retained between two semantic blocks.
    static let maxBlankLineRun = 3
    /// The most cells rendered as a grid before a table falls back to plain text.
    static let maxTableCells = 1200

    /// Parses `markdown` through swift-markdown's CommonMark + GFM AST.
    static func parse(_ markdown: String) -> [RichBlock] {
        RichTextMarkdownWalker(markdown).blocks
    }

    /// `markdown` with any blockquote nesting past `limit` levels flattened onto `limit`.
    ///
    /// # Why this is a *source* pass and not a walk
    ///
    /// ``maxListDepth`` can be applied while walking, because by then the tree exists.
    /// A quote cannot: swift-markdown's converter recurses once per level on the way in
    /// (`convertBlockQuote` → `convertChildren` → `convertAnyElement` → `convertBlockQuote`),
    /// so a tree deep enough to need flattening has already overflowed the stack while it
    /// was being built. cmark does not bound `>` either — its `MAX_LIST_DEPTH` gate sits on
    /// the list-marker and footnote branches only. Neither does the view chain, which
    /// recurses again to draw what the walker returns.
    ///
    /// A message of a few thousand `>` characters is one line to author, and the event
    /// stays on the relay: every client rendering that channel dies, and dies again on
    /// relaunch. This is the only place ahead of all three recursions.
    ///
    /// Only the markers are dropped, never the text beside them, and a document already
    /// within `limit` is returned unchanged rather than rebuilt — so the pass is invisible
    /// to every message anybody actually writes. That early return is also what keeps it
    /// away from a fenced block holding `>`-prefixed lines: reaching one at all takes a
    /// quote somewhere in the same message nested deeper than a reader could see.
    static func clampingQuoteDepth(_ markdown: String, limit: Int = maxQuoteDepth) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard lines.contains(where: { quoteMarkerScan($0).depth > limit }) else { return markdown }
        return lines.map { line -> String in
            let scan = quoteMarkerScan(line)
            guard scan.depth > limit else { return line }
            return String(repeating: "> ", count: limit) + line[scan.contentStart...]
        }
        .joined(separator: "\n")
    }

    /// How many blockquote markers open `line`, and where the text after them begins.
    ///
    /// CommonMark's own shape: up to three spaces of indent, `>`, then one optional
    /// space, repeated. A fourth space is an indented code block rather than more
    /// nesting, so the count stops there exactly where cmark's does.
    private static func quoteMarkerScan(_ line: String) -> (depth: Int, contentStart: String.Index) {
        var index = line.startIndex
        var depth = 0
        while index < line.endIndex {
            var probe = index
            var indent = 0
            while probe < line.endIndex, line[probe] == " ", indent < 3 {
                probe = line.index(after: probe)
                indent += 1
            }
            guard probe < line.endIndex, line[probe] == ">" else { break }
            depth += 1
            index = line.index(after: probe)
            if index < line.endIndex, line[index] == " " { index = line.index(after: index) }
        }
        return (depth, index)
    }

    /// Whether `trimmed` is a thematic break: CommonMark's rule characters or the
    /// reference renderer's U+2E3B horizontal bar.
    static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard let first = stripped.first, stripped.allSatisfy({ $0 == first }) else { return false }
        if first == "\u{2E3B}" { return true }
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.count >= 3
    }

    /// One pipe row split on unescaped pipes, preserving meaningful empty cells.
    static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                if character != "|" { current.append("\\") }
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current)

        if cells.count > 1, cells[0].trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeFirst()
        }
        if cells.count > 1, cells[cells.count - 1].trimmingCharacters(in: .whitespaces).isEmpty {
            cells.removeLast()
        }
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func tableAlignments(_ line: String) -> [RichTableAlignment]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        let alignments = cells.compactMap(RichTableAlignment.init(delimiterCell:))
        return alignments.count == cells.count ? alignments : nil
    }
}
