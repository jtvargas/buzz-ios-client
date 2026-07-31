import SwiftUI
import UIKit

/// Hands a control the finger the moment it lands, instead of a sixth of a second later.
///
/// # The delay this exists to remove
///
/// A `UIScrollView` holds on to the touches that land on its content while it decides whether
/// they are the beginning of a scroll. That is `delaysContentTouches`, it is `true` by default,
/// and it is true of every `List` and every `ScrollView` SwiftUI builds — so a control inside
/// one does not learn it has been pressed until about 150ms after it was, which is most of the
/// life of a quick tap.
///
/// That delay is the difference the owner named after three rounds of the shrink being
/// reported invisible: *"immediate press feedback — the visual response starts the moment the
/// finger touches the screen."* No scale, no curve and no minimum on-screen time can be seen
/// through a delay standing in front of them, because at touch-down the press has not been
/// reported to anything yet. The scale was arriving. It was arriving late, and on the shortest
/// taps it was arriving after the finger had gone.
///
/// # The pan still wins
///
/// `canCancelContentTouches` — left at its default and set here anyway, so nothing depends on
/// that default staying put — means the scroll view takes the touch back the instant it starts
/// scrolling, and that arrives at the control as a *cancelled* press. So a flick shows the
/// press on the row it began on for as long as UIKit takes to recognise a scroll and not a
/// frame longer: ``PressFeedback/cancel`` is a sixth of the release curve and has no minimum
/// in front of it. This is the trade the owner asked for in both directions at once — feedback
/// at touch-down, and no highlight trailing a scrolling finger — and it is the same trade
/// Slack makes.
extension View {
    /// Takes the scrolling ancestors' touch delay off, for this view and everything else
    /// inside them. See ``ScrollTouchDeliveryView``.
    func immediateScrollTouchDelivery() -> some View {
        background {
            ScrollTouchDelivery()
                // Load-bearing: this is a vantage point, never a target. It reads its own
                // ancestors and nothing else, and must not be in the way of the press it
                // exists to hurry along.
                .allowsHitTesting(false)
        }
    }
}

private struct ScrollTouchDelivery: UIViewRepresentable {
    func makeUIView(context _: Context) -> ScrollTouchDeliveryView { ScrollTouchDeliveryView() }
    func updateUIView(_: ScrollTouchDeliveryView, context _: Context) {}
}

/// A view that draws nothing and exists to reach its own scrolling ancestors.
final class ScrollTouchDeliveryView: UIView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        Self.deliverImmediately(above: self)
    }

    /// Takes the delay off **every** scrolling ancestor, not just the nearest.
    ///
    /// Every one, because they nest: a reaction chip sits in a horizontal scroll view inside
    /// the conversation's own, and the outer one delays the touch before the inner one ever
    /// sees it. Stopping at the first would leave the chip exactly as late as it was.
    ///
    /// Nothing is put back when the view goes away, deliberately. Several controls inside one
    /// list each ask for this, so a restore would be one of them re-arming the delay while the
    /// others are still relying on it being gone. The flag is idempotent, and these are the
    /// app's own scroll views.
    @discardableResult
    static func deliverImmediately(above view: UIView) -> [UIScrollView] {
        var found: [UIScrollView] = []
        var candidate = view.superview
        while let next = candidate {
            if let scrollView = next as? UIScrollView {
                scrollView.delaysContentTouches = false
                scrollView.canCancelContentTouches = true
                found.append(scrollView)
            }
            candidate = next.superview
        }
        return found
    }
}
