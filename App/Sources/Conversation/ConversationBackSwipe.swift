import SwiftUI
import UIKit

extension View {
    /// Restores a left-edge swipe that goes back, for a surface that has hidden its system
    /// navigation bar.
    ///
    /// See ``ConversationBackSwipe`` for what was measured. The short version: hiding the bar
    /// does not disable UIKit's own pop recogniser, but it does stop it recognising, and the
    /// difference is invisible in every property you can read off it.
    func conversationBackSwipe() -> some View {
        modifier(ConversationBackSwipeModifier())
    }
}

private struct ConversationBackSwipeModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.gesture(ConversationBackSwipe { dismiss() })
    }
}

/// A left-edge pan that pops the conversation, standing in for the system's own.
///
/// # Why this exists
///
/// The header is three floating capsules on one row, which needs the system navigation bar
/// hidden — a 44pt bar cannot hold a two-line pill at back-button level, and stacking our row
/// under an empty bar is the ~100pt of chrome the owner rejected. Hiding it costs the
/// interactive pop gesture.
///
/// That cost was measured, not assumed, and it is worth recording *how* — because the obvious
/// instrument lies. Driving a real left-edge drag through XCUITest on iPhone 17 Pro / iOS 26,
/// with the same drag against a bar-visible control:
///
/// | surface | drag pops? |
/// |---|---|
/// | system bar visible | yes |
/// | system bar hidden | **no** |
/// | system bar hidden, `interactivePopGestureRecognizer.isEnabled` forced back to `true` | **no** |
///
/// And at the same time, every property of the recogniser reads *identically* in both cases:
/// `isEnabled=true`, `delegate=_UINavigationInteractiveTransition`, attached to the same
/// `UILayoutContainerView`, the same two `_UIParallaxTransitionPanGestureRecognizer`s on the
/// navigation controller's view. The only difference is `isNavigationBarHidden`. So UIKit's
/// refusal happens inside that delegate's `gestureRecognizerShouldBegin`, where no public
/// property exposes it — a probe that logged `isEnabled` and stopped there would have
/// reported the gesture healthy while it was dead.
///
/// # What this is, and what it is not
///
/// A `UIScreenEdgePanGestureRecognizer` only begins within the system's own left-edge band and
/// only for a roughly horizontal movement, so a vertical drag that starts at the edge still
/// belongs to the message list. What it does *not* reproduce is interactivity: the system
/// gesture drags the previous screen in under your thumb and can be abandoned half-way, while
/// this commits on release once the drag has gone far enough or fast enough. Matching the
/// interactive version means driving `UINavigationController`'s transition, which has no public
/// entry point.
///
/// If a future SDK makes a hidden bar keep its gesture, delete this and the
/// `.conversationBackSwipe()` call in ``ConversationScaffold``; the XCUITest in
/// `~/.buzz/.scratch/headerharness` is the check for that.
///
/// Internal rather than private so the commit band below is reachable from tests.
struct ConversationBackSwipe: UIGestureRecognizerRepresentable {
    let onBack: () -> Void

    /// How far, or how fast, before a release counts as going back. The distance is roughly
    /// the system's own commit point and the velocity is what makes a flick work without it.
    private static let commitDistance: CGFloat = 60
    private static let commitVelocity: CGFloat = 300

    func makeUIGestureRecognizer(context _: Context) -> UIScreenEdgePanGestureRecognizer {
        let recogniser = UIScreenEdgePanGestureRecognizer()
        recogniser.edges = .left
        return recogniser
    }

    func handleUIGestureRecognizerAction(
        _ recogniser: UIScreenEdgePanGestureRecognizer,
        context _: Context
    ) {
        guard recogniser.state == .ended else { return }
        let translation = recogniser.translation(in: recogniser.view)
        let velocity = recogniser.velocity(in: recogniser.view)
        guard Self.commits(translationX: translation.x, velocityX: velocity.x) else { return }
        onBack()
    }

    /// Whether a release at this point counts as going back.
    ///
    /// Split out and pure so the commit band is a tested number rather than two literals
    /// buried in a delegate callback.
    static func commits(translationX: CGFloat, velocityX: CGFloat) -> Bool {
        translationX >= commitDistance || velocityX >= commitVelocity
    }
}
