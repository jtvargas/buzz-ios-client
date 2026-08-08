import Foundation

/// Parses message markdown into the typed blocks shared by every renderer and
/// downstream rich-text pass.
enum RichTextParser {
    /// The deepest nested list level materialised from untrusted input. The root
    /// list is level zero; deeper authored levels collapse into level eight.
    static let maxListDepth = 8
    /// The most authored blank lines retained between two semantic blocks.
    static let maxBlankLineRun = 3
    /// The most cells rendered as a grid before a table falls back to plain text.
    static let maxTableCells = 1200

    /// Parses `markdown` through swift-markdown's CommonMark + GFM AST.
    static func parse(_ markdown: String) -> [RichBlock] {
        RichTextMarkdownWalker(markdown).blocks
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
