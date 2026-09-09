import SwiftUI
import UIKit

// MARK: - State

/// How far the workspace panel is out, and who is moving it.
///
/// One object rather than a `Bool` and an offset, because the panel has no open/closed state
/// worth naming apart from its position: the pill's tap is the drag's endpoint reached in one
/// animation, and a reader who stops half way is in a state the app has to be able to draw.
@MainActor
@Observable
final class WorkspacePanelState {
    /// 0 is off-screen, 1 is fully over the sidebar.
    var progress: CGFloat = 0

    var isOpen: Bool { progress > 0 }

    /// Opens or closes under an animation, for the callers that are not a finger — the pill,
    /// the scrim's tap, a community being switched to.
    func setOpen(_ open: Bool) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
            progress = open ? 1 : 0
        }
    }
}

// MARK: - The gesture

/// A pan that gives up unless the hand meant the one direction that is free right now.
///
/// The mirror of ``LeftwardPanGestureRecognizer``, and it has to make the same decision for
/// the same reason: the sidebar is a vertically scrolling list, so the direction has to be
/// judged *before* the recogniser claims the touch. It reads the first 10pt of travel and
/// fails on anything that is not clearly along the wanted axis — which is also what keeps a
/// tap on a row a tap, since a tap does not travel.
///
/// Which direction is wanted depends on where the panel already is, so it is asked rather
/// than fixed: closed, only rightward may begin; open, only leftward. That is what stops this
/// and the sidebar's leftward drag both claiming the same hand.
final class WorkspacePanGestureRecognizer: UIPanGestureRecognizer {
    /// How far the touch travels before the direction is judged.
    private static let decisionDistance: CGFloat = 10
    /// How much more horizontal than vertical that travel has to be.
    private static let dominance: CGFloat = 1.2

    /// Whether a rightward drag is the one that means something right now. Read at the
    /// moment of the decision rather than stored, because the panel can be moved by
    /// something other than a finger between one touch and the next.
    var wantsRightward: () -> Bool = { true }

    private var origin: CGPoint?
    private var decided = false

    override func reset() {
        super.reset()
        origin = nil
        decided = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        origin = touches.first?.location(in: nil)
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // Judged before `super`, because `super` is what begins the gesture and a recogniser
        // cannot be failed once it has begun.
        if !decided, let origin, let point = touches.first?.location(in: nil) {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            if abs(dx) + abs(dy) >= Self.decisionDistance {
                decided = true
                let along = wantsRightward() ? dx > 0 : dx < 0
                if !along || abs(dx) <= abs(dy) * Self.dominance {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

// MARK: - Installation

/// Puts the workspace drag on the channel list's navigation controller.
///
/// On that controller's view rather than on this one, for the reason
/// ``SidebarForwardSwipeView`` gives: this view lives inside the sidebar, and a recogniser on
/// a view that can leave the hierarchy mid-drag is a recogniser cancelled mid-drag. The
/// navigation controller's view outlives everything drawn inside it.
final class WorkspacePanelDragView: UIView, UIGestureRecognizerDelegate {
    /// The panel this drag moves, or `nil` to refuse to start one.
    var state: WorkspacePanelState?
    /// Whether the sidebar is the screen on top. A conversation on the stack has its own
    /// rightward meaning — it is the system's back swipe — and this must not compete with it.
    var isAvailable = true

    private weak var host: UIView?
    /// Where the panel was when the current drag began. A drag is a *change* from wherever
    /// the panel already is, which is what lets one begin on a panel that is already open.
    private var startProgress: CGFloat = 0
    /// Whether the panel was out when the current drag began, judged by the same fraction
    /// that decides where a release lands (``WorkspacePanelGeometry/commitFraction``).
    ///
    /// Held so the release can tell an *opening* from a drag that merely wandered and sprang
    /// back — which is the whole of what the haptic answers. Recorded rather than derived from
    /// ``startProgress`` at the end, because the panel may be mid-animation when a hand catches
    /// it and `progress > 0` would call that already open.
    private var startedOpen = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, host == nil else { return }
        // Not reachable on this turn: the navigation controller above this view is still
        // being assembled, and asking for it now answers nil.
        DispatchQueue.main.async { [weak self] in self?.install() }
    }

    private func install() {
        guard host == nil, let navigation = navigationController()?.view else { return }
        // Idempotent, so a rebuilt sidebar does not stack recognisers on a shared view.
        for existing in navigation.gestureRecognizers ?? [] where existing is WorkspacePanGestureRecognizer {
            navigation.removeGestureRecognizer(existing)
        }
        let pan = WorkspacePanGestureRecognizer(target: self, action: #selector(handle))
        pan.delegate = self
        pan.wantsRightward = { [weak self] in !(self?.state?.isOpen ?? false) }
        navigation.addGestureRecognizer(pan)
        host = navigation
    }

    private func navigationController() -> UINavigationController? {
        var responder: UIResponder? = self
        while let next = responder {
            if let controller = next as? UIViewController { return controller.navigationController }
            responder = next.next
        }
        return nil
    }

    private var panelWidth: CGFloat {
        WorkspacePanelGeometry.width(inScreenOf: host?.bounds.width ?? 0)
    }

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        guard let state, let host, let window = host.window else { return }
        switch pan.state {
        case .began:
            startProgress = state.progress
            startedOpen = startProgress >= WorkspacePanelGeometry.commitFraction
            // The drag has won the hand; nothing under it should still be scrolling. See
            // ``suspendScrolling(under:)``.
            suspendScrolling(under: host)
        case .changed:
            let translation = pan.translation(in: window).x
            state.progress = WorkspacePanelGeometry.progress(
                translation: translation,
                from: startProgress,
                width: panelWidth
            )
        case .ended, .cancelled, .failed:
            resumeScrolling()
            settle(state, velocity: pan.velocity(in: window).x, released: pan.state == .ended)
        default:
            break
        }
    }

    // MARK: - Scrolling, while this drag owns the hand

    /// The scroll views stopped for the duration of one drag, to be started again after it.
    ///
    /// Held strongly, and only for the length of a gesture: a weak box that emptied itself
    /// mid-drag would leave a list that never scrolls again.
    private var suspendedScrollViews: [UIScrollView] = []

    /// Stops every scroll view under `view` from scrolling while this drag runs.
    ///
    /// The direction gate cannot do this on its own. It decides at 10pt, and simultaneity
    /// with pans is what keeps the list's scrolling from beginning late — so for those first
    /// frames the scroll and this drag are both live, and a hand moving mostly sideways still
    /// carries the list a little vertically. The owner saw exactly that: "i start dragging but
    /// the scroll on the sidebar is still responding".
    ///
    /// Toggling `isEnabled` is the cancellation: UIKit sends a disabled recogniser straight to
    /// `.cancelled`, which ends the scroll rather than merely refusing the next touch. Turning
    /// it back on does not resume it — a scroll cancelled this way needs a new finger, which
    /// is the behaviour asked for.
    private func suspendScrolling(under view: UIView) {
        var found: [UIScrollView] = []
        collectScrollViews(in: view, into: &found)
        for scroll in found where scroll.panGestureRecognizer.isEnabled {
            scroll.panGestureRecognizer.isEnabled = false
            suspendedScrollViews.append(scroll)
        }
    }

    /// Gives scrolling back. Called on every ending state, including the ones nobody chose:
    /// a drag lost to a phone call must not leave a sidebar that cannot scroll.
    private func resumeScrolling() {
        for scroll in suspendedScrollViews {
            scroll.panGestureRecognizer.isEnabled = true
        }
        suspendedScrollViews.removeAll()
    }

    /// Every scroll view beneath `view`, at any depth — the sidebar's own list, and the
    /// panel's list of communities, which is inside this same subtree once the panel is out.
    private func collectScrollViews(in view: UIView, into found: inout [UIScrollView]) {
        for subview in view.subviews {
            if let scroll = subview as? UIScrollView { found.append(scroll) }
            collectScrollViews(in: subview, into: &found)
        }
    }

    /// Runs the remaining distance out under its own steam. A cancelled drag settles too —
    /// leaving the panel wherever the finger was lost would strand it half open.
    ///
    /// # The haptic
    ///
    /// It is played here and nowhere else in the drag, which is the owner's ask (2026-08-27) and
    /// the shape X's drawer has: nothing at all while the finger is down, one tick at the moment
    /// it lifts. A haptic that tracked the drag would be saying the same thing many times over
    /// during one gesture, which is the noise ``HiveHaptic`` exists to refuse.
    ///
    /// Two conditions, and both are load-bearing. `released` keeps it off `.cancelled` and
    /// `.failed` — a drag lost to an incoming call did not open anything, and the panel settling
    /// by itself is not a thing the reader did. `open != startedOpen` keeps it off a drag that
    /// wandered below the commit fraction and sprang back, which is the "at least a threshold"
    /// half of the ask: the feedback answers a *change of state*, not a gesture that happened.
    /// A flick shorter than the fraction still counts, because it still opens the panel.
    ///
    /// Before the animation rather than after it, for ``SidebarSectionHeader``'s reason: the
    /// tick belongs at the lift, and the panel takes up to
    /// ``WorkspacePanelGeometry/maximumSettle`` to arrive.
    private func settle(_ state: WorkspacePanelState, velocity: CGFloat, released: Bool) {
        let open = released
            ? WorkspacePanelGeometry.settles(open: state.progress, velocity: velocity)
            : state.progress >= WorkspacePanelGeometry.commitFraction
        let target: CGFloat = open ? 1 : 0
        if released, open != startedOpen { HiveHaptics.play(.disclosureToggled) }
        let duration = WorkspacePanelGeometry.settleDuration(
            from: state.progress,
            to: target,
            width: panelWidth,
            velocity: velocity
        )
        withAnimation(.easeOut(duration: duration)) {
            state.progress = target
        }
    }

    // MARK: - UIGestureRecognizerDelegate

    /// `override`, because `UIView` declares this too — it is the same Objective-C selector,
    /// and a plain declaration here would shadow rather than answer it.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is WorkspacePanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(recognizer)
        }
        guard state != nil, isAvailable else { return false }
        // Only from the sidebar itself. A conversation or the Threads screen on the stack is
        // a screen where rightward already means the system's back swipe.
        return navigationController()?.viewControllers.count == 1
    }

    /// Alongside the list's own scrolling, and nothing else.
    ///
    /// The reasoning is ``SidebarForwardSwipeView``'s, and it was paid for once already: a
    /// direction gate stops a drag *beginning* on a tap, but nothing in it stops a tap
    /// **finishing** on a drag. Each sidebar row is a `Button` with a custom `ButtonStyle`,
    /// so its press is SwiftUI's own gesture rather than the cell's, and a row is still under
    /// the finger when it lifts three hundred points away — which is exactly the owner's
    /// "start dragging and then navigate to a channel".
    ///
    /// Naming pans keeps the one exception that matters: the list's vertical scrolling has to
    /// stay alive, because this recogniser cannot know the hand's direction until 10pt in and
    /// a scroll made to wait for that would begin late every time.
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other is UIPanGestureRecognizer
    }
}

// MARK: - SwiftUI

/// The zero-size backing view, in the idiom the app's other UIKit reach-arounds use
/// (``SidebarForwardSwipe``, ``WindowTint``): it exists to be added to the hierarchy, find
/// what is above it, and talk to it.
struct WorkspacePanelDrag: UIViewRepresentable {
    let state: WorkspacePanelState
    let isAvailable: Bool

    func makeUIView(context _: Context) -> WorkspacePanelDragView {
        let view = WorkspacePanelDragView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: WorkspacePanelDragView, context _: Context) {
        view.state = state
        view.isAvailable = isAvailable
    }
}

extension View {
    /// Drag right anywhere on the sidebar to bring the communities over it.
    ///
    /// Anywhere, and not from the screen edge: an edge-only grab is the system's own idiom
    /// for going back, and this is not going back. It is the mirror of the leftward drag that
    /// already lives on this screen, which is also why it is declared beside it.
    func workspacePanelDrag(_ state: WorkspacePanelState, isAvailable: Bool) -> some View {
        background {
            WorkspacePanelDrag(state: state, isAvailable: isAvailable)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
