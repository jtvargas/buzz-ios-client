import SwiftUI

/// Keeps content alive while its measured height eases between zero and full size.
///
/// What it wraps is a whole section's worth of sidebar rows, inside the same list cell as the
/// heading that opens them — ``ChannelListView/sectionCell(_:resumable:)``.
///
/// # Why one of these per section and not one per row
///
/// Because **a `List` will not size a cell to nothing**, and `defaultMinListRowHeight` does not
/// lower that floor as far as it looks: setting it to zero takes the floor from 44pt to about
/// 28pt and no further. So the first fix here — one accordion per row, each row still in its
/// own cell — animated correctly and then stopped 28pt short of closed, *per hidden row*. On
/// the owner's phone that left ~500pt of dead space under three collapsed headings, measured
/// off his screenshot at 27.2/28.0/28.6pt a row across sections of 5, 8 and 5.
///
/// Nothing inside a row can fix that; the cell is the floor. With the heading in the cell the
/// floor never binds — the heading is ~50pt the cell can always stand on — and the rows below
/// it are free to reach zero. Measured in a standalone probe on the iOS 26.1 simulator
/// (`.scratch/accordionprobe`), collapsed: 28.33pt a row one-cell-per-row, exactly 0 with the
/// heading in the cell, and expanded geometry identical either way.
///
/// # It also collapses smoothly, which the per-row shape did not
///
/// One cell resizing is one height animation; eighteen cells resizing together are eighteen,
/// and the list resolves them in a couple of frames. Sampling the next heading's position
/// across a collapse in the same probe: one 143pt step per-row against ~24 continuous frames
/// with the rows in one cell. That step is the jump.
///
/// # What it costs
///
/// A section's rows are all built when the section is — a `VStack`, not a `ForEach` the list
/// can be lazy about. The sidebar's roster is bounded by the conversations one person is in,
/// each row a name and a badge, and the list was already building every section's count.
struct SidebarAccordion<Content: View>: View {
    let isExpanded: Bool
    private let content: Content

    init(isExpanded: Bool, @ViewBuilder content: () -> Content) {
        self.isExpanded = isExpanded
        self.content = content()
    }

    var body: some View {
        SidebarAccordionLayout(progress: isExpanded ? 1 : 0) { content }
            .clipped()
            .opacity(isExpanded ? 1 : 0)
            .allowsHitTesting(isExpanded)
            .accessibilityHidden(!isExpanded)
            .animation(.snappy(duration: 0.22), value: isExpanded)
    }
}

/// Conditional rows jump because `List` commits their insertion/removal before rendering a
/// transition. Stable content with an animatable intrinsic height lets the list reflow each
/// frame instead.
private struct SidebarAccordionLayout: Layout {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height * clampedProgress)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
    }

    private var clampedProgress: CGFloat { min(max(progress, 0), 1) }
}
