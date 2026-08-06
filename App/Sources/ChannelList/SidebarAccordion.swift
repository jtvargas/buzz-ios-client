import SwiftUI

/// Keeps a `List` row alive while its measured height eases between zero and full size.
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
/// transition. A stable row with an animatable intrinsic height lets the list reflow each frame.
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
