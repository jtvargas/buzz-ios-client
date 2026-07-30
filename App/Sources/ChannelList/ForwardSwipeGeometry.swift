import CoreGraphics
import Foundation

/// The numbers behind the sidebar's forward drag, and the two decisions it makes.
///
/// Separated from ``SidebarForwardSwipeView``'s machinery so the rules are testable without
/// a window: what a finger's travel means, and whether letting go opens the conversation or
/// puts it back.
enum ForwardSwipeGeometry {
    /// How far the arriving conversation is held off the trailing edge at rest, as a
    /// fraction of the screen. The system's own push moves the screen being *left* by this
    /// much while the arriving one crosses the whole width; this is that, mirrored.
    static let parallax: CGFloat = 0.3
    /// How dark the arriving conversation is under the sidebar, before it has arrived.
    static let shade: CGFloat = 0.12
    /// The share of the screen a slow drag has to cross to count as "open it".
    static let commitFraction: CGFloat = 0.32
    /// Points per second, leftward, that opens the conversation whatever the distance —
    /// and, mirrored, the rightward flick that closes it whatever the distance.
    static let flickVelocity: CGFloat = 520
    static let minimumSettle: TimeInterval = 0.14
    static let maximumSettle: TimeInterval = 0.34

    /// How far through the transition a drag of `translation` has carried it: 0 is the
    /// sidebar untouched, 1 is the conversation arrived.
    ///
    /// Leftward is negative in UIKit, so this flips the sign. Clamped at both ends: dragging
    /// back past the start does not push the sidebar off the other edge, and dragging past
    /// the far edge does not over-travel — there is nothing beyond the conversation to see.
    static func progress(translation: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return min(max(-translation / width, 0), 1)
    }

    /// Whether letting go here opens the conversation.
    ///
    /// Distance *or* speed, which is what makes a flick work: the reader who throws the
    /// sidebar aside in 60pt means it as clearly as the one who drags it two thirds of the
    /// way and stops. The rightward case is the same rule mirrored, and it is not
    /// redundant — it is how someone who has dragged 80% of the way over changes their mind.
    static func commits(progress: CGFloat, velocity: CGFloat) -> Bool {
        if velocity <= -flickVelocity { return true }
        if velocity >= flickVelocity { return false }
        return progress >= commitFraction
    }

    /// How long the release should take to finish the distance left.
    ///
    /// Proportional to what is left rather than fixed, so a release at 90% does not take as
    /// long as one at 10% — a constant duration is what makes a hand-driven transition feel
    /// like it stopped listening. Bounded at both ends: the floor keeps a near-finished
    /// release from being an instant jump, the ceiling keeps a slow one from dragging.
    static func settleDuration(from progress: CGFloat, to target: CGFloat, width: CGFloat, velocity: CGFloat)
        -> TimeInterval {
        let distance = abs(target - progress) * width
        let speed = max(abs(velocity), 900)
        return min(max(TimeInterval(distance / speed), minimumSettle), maximumSettle)
    }
}
