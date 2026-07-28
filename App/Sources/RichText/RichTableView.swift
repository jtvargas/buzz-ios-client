import SwiftUI

/// A GFM table, drawn to be read on a phone.
///
/// # The three constraints, and what each one settles
///
/// **No text may be lost.** So the table is never squeezed to fit: it is laid out at
/// the width its content needs and put inside a horizontal scroll view, which is also
/// what upstream does. Shrinking columns to the screen would either clip cells or crush
/// them into one-word-per-line towers, and both of those are the "weird cut offs" this
/// work exists to remove.
///
/// **The message row must not grow wide.** A `ScrollView` adopts the width it is
/// offered rather than its content's, so however wide the table is, the row around it
/// is exactly as wide as a paragraph would have been. Nothing else in the message
/// reflows because a table appeared in it.
///
/// **The conversation must keep scrolling.** The inner scroll view is horizontal only,
/// and `scrollBounceBehavior(.basedOnSize)` stops it claiming a gesture when its
/// content already fits — so a small table is inert and a vertical drag anywhere on the
/// message reaches the timeline underneath.
///
/// # Why the columns are capped
///
/// Inside a horizontal scroll view a cell is offered unlimited width, and a `Text`
/// offered unlimited width never wraps. One cell holding a paragraph would then be one
/// line thousands of points long. ``RichTextWidthCap`` caps what the cell is *offered*
/// — not what it is given, which is the difference between "wrap at the readable
/// measure" and "every column is 260 points wide whether it needs to be or not".
///
/// # Why there are no column rules
///
/// Upstream draws a full grid. At phone size that is a lot of line for a three-column
/// table, and a rule between columns has to be drawn to the row's full height to look
/// deliberate — which a `Grid` cell, sized to its own text, is not. Row rules plus
/// twenty points of gutter separate the columns without any of that, and the alignment
/// read from the delimiter row does the rest.
struct RichTableView: View {
    /// The per-cell width cap at this reader's text size — scaled, because a cap fixed
    /// in points would wrap accessibility sizes after two words.
    @ScaledMetric(relativeTo: .body)
    private var cellWidth: CGFloat = RichTextStyle.tableCellMaxWidth

    let table: RichTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                if table.hasHeader {
                    row(table.header, isHeader: true)
                }
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    // Emitted as an unconditional pair so the grid's children stay one
                    // shape per iteration: a rule, then the row it separates from what
                    // is above it. With a header always present on a parsed table, that
                    // never leaves a stray rule at the top.
                    Divider().gridCellUnsizedAxes(.horizontal)
                    row(cells, isHeader: false)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: RichTextStyle.tableBorderRadius, style: .continuous)
                    .strokeBorder(Color.secondary.opacity(0.3), lineWidth: 1)
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Table")
    }

    private func row(_ cells: [AttributedString], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                self.cell(cell, column: column, isHeader: isHeader)
            }
        }
    }

    @ViewBuilder
    private func cell(_ content: AttributedString, column: Int, isHeader: Bool) -> some View {
        let alignment = table.alignments.indices.contains(column) ? table.alignments[column] : .leading
        RichTextWidthCap(maxWidth: cellWidth) {
            RichTextInline.text(content, base: .body)
                // The header's weight is named while the font is built rather than
                // layered on with `.fontWeight(_:)`, which the app's typeface drops —
                // a static family has no weight axis to answer it, so the modifier
                // would compile, run, and leave the header row set like the body.
                .font(.hive(.body, weight: isHeader ? .semibold : .regular))
                .multilineTextAlignment(alignment.textAlignment)
        }
        .padding(.horizontal, RichTextStyle.tableCellPadding.width)
        .padding(.vertical, RichTextStyle.tableCellPadding.height)
        // Stated on every cell rather than on one of them. `gridColumnAlignment` sets
        // the column's alignment and the grid's behaviour when two cells in a column
        // disagree is not specified — so they are made to agree instead: each cell
        // reads the same column's alignment, and whichever one the grid honours is the
        // same answer.
        .gridColumnAlignment(alignment.gridAlignment)
    }
}

private extension RichTableAlignment {
    var textAlignment: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var gridAlignment: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Offers its content at most `maxWidth`, and takes the size the content actually used.
///
/// # The thing `frame(maxWidth:)` cannot do
///
/// A frame with a maximum bounds the *result*; it does not bound what the content is
/// offered. A horizontal scroll view offers its content an unspecified width, so a
/// `Text` inside one lays out on a single line however long that line is, and a
/// `.frame(maxWidth: 260)` around it then trims the box down to 260 points with the
/// line still running out the side of it.
///
/// Measured in a harness, one long cell inside a 330-point column:
///
/// | wrapper | height | what happened |
/// |---|---|---|
/// | `frame(maxWidth: 260)` | 16pt | one line, cut off at 260 |
/// | this layout | 144pt | nine lines, all of it on screen |
///
/// A `Layout` can separate the two halves the frame conflates: cap the proposal on the
/// way down, so the text wraps, and report the size the text actually used on the way
/// up, so a two-letter cell still measures two letters.
struct RichTextWidthCap: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = min(proposal.width ?? maxWidth, maxWidth)
        return subview.sizeThatFits(ProposedViewSize(width: width, height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.minX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )
    }
}
