import CoreGraphics
import Foundation

/// The numbers behind the workspace panel's drag, and the one decision it makes.
///
/// Separated from the recogniser for the reason ``ForwardSwipeGeometry`` is: what a finger's
/// travel means, and whether letting go leaves the panel open, are rules worth asserting
/// without a window to put them in.
///
/// This is the mirror of that file. The sidebar's existing drag goes *leftward* and reopens
/// the conversation you just left; this one goes *rightward* and brings the communities over
/// the top of it. Same thresholds, opposite signs — a hand that has learned one has learned
/// the other.
enum WorkspacePanelGeometry {
    /// How much of the screen the panel covers. The owner's number, chosen on a device on
    /// 2026-08-03: `0.85` originally, tried at `0.70`, settled at `0.75`. The strip left over
    /// is what you tap to go back, so it has to stay wide enough to be a target — a quarter of
    /// the screen here, against the sliver `0.85` left. That is his trade, made by looking at
    /// all three — do not quietly tune it back toward Slack's.
    static let widthFraction: CGFloat = 0.75
    /// How dark the sidebar goes under the open panel.
    static let scrimOpacity: CGFloat = 0.28
    /// The share of the panel's width a slow drag has to cross to leave it open.
    static let commitFraction: CGFloat = 0.32
    /// Points per second, rightward, that opens the panel whatever the distance — and,
    /// mirrored, the leftward flick that closes it whatever the distance.
    static let flickVelocity: CGFloat = 520
    static let minimumSettle: TimeInterval = 0.14
    static let maximumSettle: TimeInterval = 0.34

    /// The panel's width on a screen of `screenWidth`.
    static func width(inScreenOf screenWidth: CGFloat) -> CGFloat {
        screenWidth * widthFraction
    }

    /// How far through the opening a drag of `translation` has carried it: 0 is the panel
    /// off-screen, 1 is the panel fully over the sidebar.
    ///
    /// Measured against the *panel's* width rather than the screen's, so the panel tracks
    /// the finger exactly — a drag of 100pt moves it 100pt, and it arrives when the hand
    /// arrives rather than 15% early.
    ///
    /// `from` is where the panel already was when this drag began, which is what lets a
    /// drag that starts on an open panel push it back rather than start again from nothing.
    static func progress(translation: CGFloat, from start: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0 else { return start }
        return min(max(start + translation / width, 0), 1)
    }

    /// Whether letting go here leaves the panel open.
    ///
    /// Distance *or* speed, so a flick counts as clearly as a deliberate drag. Applied to
    /// closing too, unchanged: a hand that has pushed an open panel most of the way back is
    /// below the fraction and it closes, and one that has moved it an inch is not and it
    /// springs open again.
    static func settles(open progress: CGFloat, velocity: CGFloat) -> Bool {
        if velocity >= flickVelocity { return true }
        if velocity <= -flickVelocity { return false }
        return progress >= commitFraction
    }

    /// How long the release should take to finish the distance left — proportional to what
    /// remains, bounded at both ends. See ``ForwardSwipeGeometry/settleDuration(from:to:width:velocity:)``.
    static func settleDuration(
        from progress: CGFloat,
        to target: CGFloat,
        width: CGFloat,
        velocity: CGFloat
    ) -> TimeInterval {
        let distance = abs(target - progress) * width
        let speed = max(abs(velocity), 900)
        return min(max(TimeInterval(distance / speed), minimumSettle), maximumSettle)
    }
}
