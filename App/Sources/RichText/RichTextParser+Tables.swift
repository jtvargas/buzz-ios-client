import Foundation

/// GFM pipe-table scanning: a header row, a delimiter row that carries the column
/// alignments, and body rows until the table stops.
///
/// # Why a delimiter row is required, when upstream's is not
///
/// The reference renderer recognises a table from two consecutive pipe-bearing lines
/// and then treats the *second* one as the alignment row whether or not it is one —
/// and drops it from the render. So a message written as
///
/// ```
/// | staging | prod |
/// | 3 boxes | 9 boxes |
/// ```
///
/// draws a one-row table upstream, and the numbers are gone. Losing a row of someone's
/// message is worse than not drawing a border around it, so a delimiter row is
/// mandatory here: without one those two lines stay a paragraph, pipes and all, and
/// every character the author typed is still on screen.
///
/// The same instinct decides the cell count. GFM says a body row wider than the header
/// has its extra cells ignored; ``RichTable`` widens the table instead.
extension RichTextParser {
    /// The most cells a table may hold before it is drawn as plain text instead.
    ///
    /// A table is the one construct in this grammar whose cost grows in *two*
    /// dimensions, and it is the one construct the renderer cannot lay out lazily — a
    /// `Grid` measures every cell to find its column widths. A hundred rows of eight
    /// columns is already eight hundred `Text`s inside a single row of a scrolling
    /// list. Past the budget the lines fall back to a paragraph, which is one `Text`
    /// holding every character the author wrote: complete, cheap, and honest about
    /// being too big to tabulate.
    static let maxTableCells = 1200

    // MARK: - Detection

    /// Whether a table opens at `index`: a pipe-bearing header line, and beneath it a
    /// delimiter row with exactly as many cells.
    ///
    /// The cell-count equality is GFM's rule and it is what keeps a paragraph from
    /// turning into a table by accident — `totals | 2024` followed by a `---` rule is
    /// one cell against two, so it stays what it was written as.
    static func isTableStart(_ lines: [String], at index: Int) -> Bool {
        guard index + 1 < lines.count,
              let header = tableCells(lines[index]),
              let delimiter = tableAlignments(lines[index + 1])
        else { return false }
        return delimiter.count == header.count
    }

    // MARK: - Scanning

    /// Consumes a table from `index`, or the lines it spans as a paragraph when the
    /// grid would exceed ``maxTableCells``. `index` is advanced past every line
    /// consumed either way.
    static func tableBlock(_ lines: [String], from index: inout Int) -> RichBlock {
        let start = index
        let header = tableCells(lines[index]) ?? []
        let alignments = tableAlignments(lines[index + 1]) ?? []
        index += 2

        var rows: [[String]] = []
        while index < lines.count, let cells = tableRow(lines[index]) {
            rows.append(cells)
            index += 1
        }

        let width = max(alignments.count, max(header.count, rows.map(\.count).max() ?? 0))
        guard width * (rows.count + 1) <= maxTableCells else {
            // Every line this scan consumed, verbatim, as one paragraph — the fallback
            // that keeps an oversized table's text on screen rather than half-drawn.
            // `index` already sits past the table, so the span is exactly what was read.
            return .paragraph(InlineMarkdown.render(lines[start ..< index].joined(separator: "\n")))
        }

        return .table(RichTable(
            alignments: alignments,
            header: header.map(InlineMarkdown.render),
            rows: rows.map { $0.map(InlineMarkdown.render) }
        ))
    }

    /// A body row's cells, or `nil` when `line` no longer belongs to the table — a
    /// blank line, a fence, or any line without a pipe in it.
    ///
    /// A fence is called out separately because ` ``` ` carries no pipe *and* opens a
    /// block whose contents are raw: letting a table run into one would swallow the
    /// code's first line as a row.
    private static func tableRow(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("```"), trimmed.contains("|") else { return nil }
        return tableCells(line)
    }

    // MARK: - Row splitting

    /// One row split into cells on unescaped pipes, each trimmed, or `nil` when the
    /// line carries no pipe at all.
    ///
    /// Two rules earn their keep here:
    ///
    /// - `\|` is a literal pipe inside a cell (GFM), so the split has to walk the
    ///   characters rather than call `components(separatedBy:)`. A table of shell
    ///   commands is the common case, and splitting one on its own pipes shreds it.
    /// - the empty cell a *leading* or *trailing* pipe produces is dropped, and only
    ///   that one. The reference drops *every* empty cell, which slides `| a | | c |`
    ///   left into a two-column row and files `c` under `b`'s heading — a silently
    ///   wrong table, which is worse than an ugly one.
    static func tableCells(_ line: String) -> [String]? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.contains("|") else { return nil }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                // A backslash only escapes a pipe here; anything else keeps both
                // characters, so a Windows path in a cell survives intact.
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

    /// The column alignments a delimiter row describes, or `nil` when `line` is not a
    /// delimiter row. Every cell has to be one: a single ordinary cell disqualifies the
    /// line, which is what stops a body row of dashes from ending the table early.
    static func tableAlignments(_ line: String) -> [RichTableAlignment]? {
        guard let cells = tableCells(line), !cells.isEmpty else { return nil }
        var alignments: [RichTableAlignment] = []
        for cell in cells {
            guard let alignment = RichTableAlignment(delimiterCell: cell) else { return nil }
            alignments.append(alignment)
        }
        return alignments
    }
}
