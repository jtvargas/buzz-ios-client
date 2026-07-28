import Foundation

/// How one table column's cells sit in their column, read from the delimiter row's
/// colons (`:---`, `---:`, `:---:`). GFM's three, and no more: a table has no notion
/// of a justified or a baseline-aligned column.
enum RichTableAlignment: Equatable, Sendable {
    case leading
    case center
    case trailing

    /// The alignment a delimiter cell describes, or `nil` when the cell is not a
    /// delimiter at all — which is what disqualifies a line from being the row that
    /// turns two lines of pipes into a table.
    ///
    /// GFM's rule, not the reference renderer's: at least one `-`, optional leading
    /// and/or trailing `:`, and nothing else. The reference's `^:?--+:?$` demands two
    /// dashes, which quietly rejects the perfectly ordinary `| - | - |`.
    init?(delimiterCell cell: String) {
        var body = Substring(cell)
        let leading = body.hasPrefix(":")
        if leading { body = body.dropFirst() }
        let trailing = body.hasSuffix(":")
        if trailing { body = body.dropLast() }
        guard !body.isEmpty, body.allSatisfy({ $0 == "-" }) else { return nil }
        switch (leading, trailing) {
        case (true, true): self = .center
        case (false, true): self = .trailing
        default: self = .leading
        }
    }
}

/// A GFM pipe table, already split into cells and inline-parsed.
///
/// # The shape the renderer is allowed to assume
///
/// Every row — header and body alike — is exactly ``columnCount`` cells long, because
/// the initialiser pads the short ones. That is not tidiness: a `Grid` whose rows
/// disagree about their column count silently drops the missing cells' *neighbours*
/// out of alignment, and the message would then read as a different table than the one
/// that was written. Padding here means the renderer has no ragged-row case at all.
///
/// The column count is the *widest* row, never the header's width. GFM says a body row
/// with more cells than the header has its extras ignored; ignoring them would lose
/// text, which is the one thing this pipeline may not do. A table wider than its own
/// header simply grows a nameless column.
struct RichTable: Equatable, Sendable {
    /// One alignment per column, padded with `.leading` when the delimiter row was
    /// narrower than the widest body row.
    let alignments: [RichTableAlignment]
    /// The header row's cells, or empty when the table has no header. Padded to
    /// ``columnCount``.
    let header: [AttributedString]
    /// The body rows, each padded to ``columnCount``.
    let rows: [[AttributedString]]

    var columnCount: Int { alignments.count }

    /// Whether the table carries a header row to draw differently from the body.
    var hasHeader: Bool { !header.isEmpty }

    init(alignments: [RichTableAlignment], header: [AttributedString], rows: [[AttributedString]]) {
        let width = max(
            alignments.count,
            max(header.count, rows.map(\.count).max() ?? 0)
        )
        self.alignments = Self.padded(alignments, to: width, with: .leading)
        self.header = header.isEmpty ? [] : Self.padded(header, to: width, with: AttributedString())
        self.rows = rows.map { Self.padded($0, to: width, with: AttributedString()) }
    }

    private static func padded<Element>(_ values: [Element], to width: Int, with filler: Element) -> [Element] {
        guard values.count < width else { return values }
        return values + Array(repeating: filler, count: width - values.count)
    }

    /// This table with `transform` applied to every cell it holds, header included.
    ///
    /// The hook the post-markdown passes reach cells through: a `@mention` or a bare
    /// URL inside a table cell has to light up exactly as it does in a paragraph, and
    /// the only way that stays true is for autolinking and entity resolution to walk
    /// the cells through the same ``[RichBlock]/mapInlines(_:)`` they walk everything
    /// else through.
    func mapCells(_ transform: (AttributedString) -> AttributedString) -> RichTable {
        RichTable(
            alignments: alignments,
            header: header.map(transform),
            rows: rows.map { $0.map(transform) }
        )
    }

    /// Every cell in reading order — header first, then each body row left to right.
    /// Backs the one-line snippet flattening.
    var cellsInReadingOrder: [AttributedString] {
        header + rows.flatMap { $0 }
    }
}
