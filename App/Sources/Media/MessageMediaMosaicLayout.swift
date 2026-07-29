import SwiftUI

/// The grid a message's *consecutive* pictures are drawn in — desktop's shape, taken
/// value for value, because desktop is the client that actually groups them
/// (`buzz/desktop/src/shared/ui/markdown.tsx:1251-1270`, the `ImageMosaic` component).
///
/// One deliberate departure: desktop's own container caps at 512pt (`max-w-lg`), sized
/// for its wider message column. Reusing that literally would run the mosaic past the
/// edge of a Hive message row, so ``maximumWidth`` is taken from ``MessageMediaLayout``
/// instead — the cap this app's own column already reserves a single attachment within.
///
/// Every cell is a fixed rectangle handed out before a single byte of any of its
/// pictures has arrived, for the same reason ``MessageMediaLayout/box(availableWidth:for:)``
/// is: nothing about a row's height may depend on what loads into it.
enum MessageMediaMosaicLayout {
    /// A grid cell's height outside the triptych — desktop's `h-48` (192px).
    static let cellHeight: CGFloat = 192
    /// The triptych's total height — desktop's `h-80` (320px).
    static let triptychHeight: CGFloat = 320
    /// Gap between cells, both axes — desktop's `gap-1.5` (6px).
    static let gap: CGFloat = 6
    /// The corner radius the whole mosaic clips to — desktop's `rounded-2xl` (16px).
    /// Individual cells carry none of their own; only the outer frame is rounded.
    static let cornerRadius: CGFloat = 16
    /// The widest a mosaic is drawn — see the type's doc for why this is not desktop's
    /// own 512pt.
    static let maximumWidth: CGFloat = MessageMediaLayout.maximumWidth

    /// One frame per picture, in reading order, for `count` pictures in a row
    /// `availableWidth` points wide.
    ///
    /// - Two split a row evenly.
    /// - Three form a hero-and-stack triptych: the first spans the full height at the
    ///   leading column, the other two stack in the trailing one.
    /// - Four or more lay out two per row; an odd count past three lets its last
    ///   picture span the full width of its own final row, rather than leaving a
    ///   dangling half-empty cell.
    ///
    /// Empty for `count <= 1` — a single picture is not a mosaic, see
    /// ``MessageMediaGroupView``.
    static func frames(count: Int, availableWidth: CGFloat) -> [CGRect] {
        guard count > 1 else { return [] }
        let width = min(
            availableWidth.isFinite && availableWidth > 0 ? availableWidth : maximumWidth,
            maximumWidth
        )
        return count == 3 ? triptychFrames(width: width) : gridFrames(count: count, width: width)
    }

    /// The height a mosaic of `count` pictures reserves, independent of width.
    static func totalHeight(count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        guard count != 3 else { return triptychHeight }
        let rows = rowCount(count: count)
        return cellHeight * CGFloat(rows) + gap * CGFloat(max(0, rows - 1))
    }

    /// How many rows `count` pictures fill outside the triptych: pairs, plus one more
    /// if a last picture is left over to span the row alone.
    private static func rowCount(count: Int) -> Int {
        count % 2 == 0 ? count / 2 : count / 2 + 1
    }

    private static func triptychFrames(width: CGFloat) -> [CGRect] {
        let columnWidth = (width - gap) / 2
        let stackHeight = (triptychHeight - gap) / 2
        return [
            CGRect(x: 0, y: 0, width: columnWidth, height: triptychHeight),
            CGRect(x: columnWidth + gap, y: 0, width: columnWidth, height: stackHeight),
            CGRect(x: columnWidth + gap, y: stackHeight + gap, width: columnWidth, height: stackHeight),
        ]
    }

    private static func gridFrames(count: Int, width: CGFloat) -> [CGRect] {
        let columnWidth = (width - gap) / 2
        let hasOddTail = count % 2 == 1
        let pairedCount = hasOddTail ? count - 1 : count

        var frames: [CGRect] = []
        var row = 0
        var index = 0
        while index < pairedCount {
            let originY = CGFloat(row) * (cellHeight + gap)
            frames.append(CGRect(x: 0, y: originY, width: columnWidth, height: cellHeight))
            frames.append(CGRect(x: columnWidth + gap, y: originY, width: columnWidth, height: cellHeight))
            index += 2
            row += 1
        }
        if hasOddTail {
            let originY = CGFloat(row) * (cellHeight + gap)
            frames.append(CGRect(x: 0, y: originY, width: width, height: cellHeight))
        }
        return frames
    }
}

/// Reserves ``MessageMediaMosaicLayout/frames(count:availableWidth:)`` for its subviews,
/// one cell each — the multi-picture sibling of ``MessageMediaReservation``, and pure
/// layout for the same reason: the grid is decided before any of its pictures have
/// loaded, so a `Layout` imposes it on the content rather than negotiating.
struct MessageMediaMosaicReservation: Layout {
    /// How many cells to reserve. Fixed at the view's construction — the subviews given
    /// to `placeSubviews` are always exactly this many, one per picture in the group.
    let count: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = min(
            proposal.width ?? MessageMediaMosaicLayout.maximumWidth,
            MessageMediaMosaicLayout.maximumWidth
        )
        return CGSize(width: width, height: MessageMediaMosaicLayout.totalHeight(count: count))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = MessageMediaMosaicLayout.frames(count: count, availableWidth: bounds.width)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: frame.width, height: frame.height)
            )
        }
    }
}
