import Foundation

/// Nested-list scanning. A list is a contiguous run of bullet/ordered lines (no
/// blank line between them — a blank line ends the list, matching the paragraph
/// scanner's break rule); indentation nests items into sub-lists.
extension RichTextParser {
    enum ListKind: Equatable { case bullet, ordered }

    /// One classified list line: its indentation *level* (already normalised and
    /// depth-clamped by ``listBlock(_:from:)``), marker kind, ordered start number,
    /// any checkbox/radio marker, and inline content.
    struct ListLine {
        var indent: Int
        let kind: ListKind
        let start: Int
        var marker: RichListMarker?
        let content: String
    }

    // MARK: - Gathering

    /// Consumes a maximal run of consecutive list lines from `index` and builds its
    /// top-level list blocks. A marker-kind change at the same indentation starts a
    /// sibling block rather than dropping the remainder of the run.
    static func listBlocks(_ lines: [String], from index: inout Int) -> [RichBlock] {
        var raw: [ListLine] = []
        while index < lines.count, let line = listLine(lines[index]) {
            raw.append(line)
            index += 1
        }
        let leveled = leveled(raw)
        var cursor = 0
        var blocks: [RichBlock] = []
        while cursor < leveled.count {
            blocks.append(makeList(leveled, &cursor, level: leveled[cursor].indent))
        }
        return blocks
    }

    /// Classifies one raw line as a list item, or `nil` when it is not one. Records
    /// the leading indentation (tabs expanded to four spaces) so nesting can be
    /// derived from it.
    ///
    /// A bare `[ ] todo` or `( ) one` is classified as a *bullet* item carrying the
    /// marker instead of one. That is what lets the list machinery — nesting, sibling
    /// blocks, the depth clamp — hold task lines without a second copy of it, and the
    /// renderer never draws a dot beside a checkbox because a marker replaces it.
    static func listLine(_ line: String) -> ListLine? {
        let expanded = line.replacingOccurrences(of: "\t", with: "    ")
        let indent = expanded.prefix { $0 == " " }.count
        let body = String(expanded.drop { $0 == " " })
        if isBullet(body) {
            let content = String(body.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            let task = taskItem(content)
            return ListLine(
                indent: indent,
                kind: .bullet,
                start: 1,
                marker: task?.marker,
                content: task?.content ?? content
            )
        }
        if let ordered = orderedItem(body) {
            let task = taskItem(ordered.content)
            return ListLine(
                indent: indent,
                kind: .ordered,
                start: ordered.start,
                marker: task?.marker,
                content: task?.content ?? ordered.content
            )
        }
        if let task = taskItem(body) {
            return ListLine(indent: indent, kind: .bullet, start: 1, marker: task.marker, content: task.content)
        }
        return nil
    }

    /// Maps each distinct raw indentation to a consecutive level `0, 1, 2, …`,
    /// clamped at ``maxListDepth`` so runaway indentation cannot deepen the tree (or
    /// the recursion) without bound. Ties any two raw indents that share a clamped
    /// level into the same level, flattening pathological depth.
    private static func leveled(_ raw: [ListLine]) -> [ListLine] {
        let distinct = Set(raw.map(\.indent)).sorted()
        var levelOf: [Int: Int] = [:]
        for (offset, indent) in distinct.enumerated() {
            levelOf[indent] = min(offset, maxListDepth)
        }
        return raw.map { line in
            var copy = line
            copy.indent = levelOf[line.indent] ?? 0
            return copy
        }
    }

    // MARK: - Tree building

    /// Builds one list (all items at exactly `level` sharing the first item's kind)
    /// from `lines[i...]`, recursing into deeper-level runs as each item's children.
    /// `i` is advanced past every line this list consumes.
    private static func makeList(_ lines: [ListLine], _ cursor: inout Int, level: Int) -> RichBlock {
        let kind = lines[cursor].kind
        let start = lines[cursor].start
        var items: [RichListItem] = []

        while cursor < lines.count, lines[cursor].indent == level, lines[cursor].kind == kind {
            let content = InlineMarkdown.render(lines[cursor].content)
            let marker = lines[cursor].marker
            cursor += 1

            var children: [RichBlock] = []
            while cursor < lines.count, lines[cursor].indent > level {
                children.append(makeList(lines, &cursor, level: lines[cursor].indent))
            }
            items.append(RichListItem(content: content, marker: marker, children: children))
        }

        return kind == .bullet ? .bulletList(items) : .orderedList(start: start, items)
    }

    // MARK: - Marker classifiers

    static func isBullet(_ body: String) -> Bool {
        body.hasPrefix("- ") || body.hasPrefix("* ") || body.hasPrefix("+ ")
    }

    /// The marker and remaining content of a task line — `[ ] todo`, `[x] done`,
    /// `( ) one`, `(x) one` — or `nil` when `body` does not open with one.
    ///
    /// Deliberately narrow. Only a space or an `x` sits inside the brackets, a single
    /// space has to follow them, and something non-blank has to follow *that*. A
    /// looser rule turns `[0] is the first element` into a ticked checkbox, and the
    /// author's `[0]` disappears into a glyph — exactly the kind of quiet text loss
    /// this pipeline exists to avoid.
    static func taskItem(_ body: String) -> (marker: RichListMarker, content: String)? {
        let opening = Array(body.prefix(4))
        guard opening.count == 4, opening[3] == " " else { return nil }

        let make: (Bool) -> RichListMarker
        switch (opening[0], opening[2]) {
        case ("[", "]"): make = RichListMarker.checkbox
        case ("(", ")"): make = RichListMarker.radio
        default: return nil
        }

        let state: Bool
        switch opening[1] {
        case " ": state = false
        case "x", "X": state = true
        default: return nil
        }

        let content = String(body.dropFirst(4)).trimmingCharacters(in: .whitespaces)
        guard !content.isEmpty else { return nil }
        return (make(state), content)
    }

    /// The start number and content of an ordered-list line (`1. text` / `2) text`),
    /// or `nil` when the line is not an ordered item.
    static func orderedItem(_ body: String) -> (start: Int, content: String)? {
        let digits = body.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9, let start = Int(digits) else { return nil }
        let afterDigits = body.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.hasPrefix(" ") else { return nil }
        return (start, String(afterDelimiter).trimmingCharacters(in: .whitespaces))
    }
}
