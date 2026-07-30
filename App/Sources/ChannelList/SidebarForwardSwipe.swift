import SwiftUI
import UIKit

// MARK: - The gesture

/// A pan that gives up unless the hand meant "leftward".
///
/// The sidebar is a vertically scrolling list, so this has to decide *before* it claims the
/// touch — a recogniser that begins and then discovers the finger was going down has already
/// taken the scroll away for those frames. It reads the first 10pt of travel and fails on
/// anything that is not clearly leftward, which is also what keeps a tap on a row a tap and
/// a long press on a row a long press: neither travels.
///
/// The reading is in *window* coordinates, not the recogniser's view. Its view is inside the
/// one this transition parallaxes, so once the drag is under way that view is moving, and a
/// translation measured against a moving frame of reference is not the hand's.
final class LeftwardPanGestureRecognizer: UIPanGestureRecognizer {
    /// How far the touch travels before the direction is judged.
    private static let decisionDistance: CGFloat = 10
    /// How much more horizontal than vertical that travel has to be. Loose enough that a
    /// real hand's arc still reads as horizontal, tight enough that a diagonal scroll does
    /// not.
    private static let dominance: CGFloat = 1.2

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
        // Judged before `super`, because `super` is what begins the gesture: a recogniser
        // cannot be failed once it has begun.
        if !decided, let origin, let point = touches.first?.location(in: nil) {
            let dx = point.x - origin.x
            let dy = point.y - origin.y
            if abs(dx) + abs(dy) >= Self.decisionDistance {
                decided = true
                if dx >= 0 || abs(dx) <= abs(dy) * Self.dominance {
                    state = .failed
                    return
                }
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

// MARK: - The transition

/// One run of the forward transition: the picture of the sidebar being left, and the
/// arriving conversation behind it.
///
/// # Why this is hand-drawn rather than a UIKit interactive transition
///
/// Because there is no transition to drive. Measured on iOS 26 in a standalone harness
/// reproducing this app's exact shape — `TabView` → `Tab` → `NavigationStack(path:)` →
/// `List`, pushing a conversation-shaped detail (`~/.buzz/.scratch/pushdrag`):
///
/// - SwiftUI's `NavigationStackCoordinator<NavigationStrategy_Phone>` is the navigation
///   controller's delegate, and it pushes with **`animated: false`** — read back from a
///   proxy delegate forwarding to it: `willShow: NavigationStackHostingController<AnyView>
///   animated=false count=2`. An unanimated push is never offered to
///   `animationControllerFor:`, which was never called in the whole run. So
///   `UIPercentDrivenInteractiveTransition` has nothing to attach to, and the SwiftUI
///   transition that *does* run is internal and takes no percentage.
/// - A transform on the navigation controller's own view is ignored — the arriving screen
///   sat at `navigation.rendered=0.0` through a four-second hold, before and after the push
///   alike. That view's frame is UIKit's to set, and it sets it.
/// - A transform on the **window's root view** holds: `root.tx=66.3 root.rendered=66.3`,
///   unchanged over six seconds and a live list underneath it. That is the one live view
///   above the tab controller, and it is what this parallaxes.
///
/// # The shape of a run
///
/// Take a picture of the screen, put it over everything, push instantly underneath it, then
/// move the picture with the finger while the conversation behind it comes up from 30%. What
/// the reader drags is exactly what they can see, which is why this is the mirror of the
/// system's back swipe rather than a push played backwards: there too, the screen under the
/// finger is the one being left, and the one arriving is revealed beneath it.
@MainActor
final class ForwardSwipeRun {
    /// The screen's width — the distance a full drag covers.
    let width: CGFloat
    private(set) var progress: CGFloat = 0

    private weak var root: UIView?
    private let picture: UIView
    private let shade: UIView
    /// Whether the transforms may be applied yet. The push's own layout pass lands a turn
    /// after the state change that causes it, and a transform applied before that pass is
    /// wiped by it — the same way the navigation controller's is, permanently.
    private var isArmed = false
    /// Whether this run has given the root view back. Checked by everything that would move
    /// it, because ``arm()`` is scheduled a turn ahead and a flick can be over before it
    /// lands — and an arm that fired after the tidy-up would leave the whole app translated
    /// 30% off the screen with nothing left to put it back.
    private var isFinished = false

    /// Snapshots the screen and covers it. Fails, changing nothing, if there is no window to
    /// work in or no picture to be had.
    init?(host: UIView) {
        guard host.bounds.width > 0,
              let window = host.window,
              let root = window.rootViewController?.view,
              let picture = root.snapshotView(afterScreenUpdates: false) else { return nil }
        width = host.bounds.width
        picture.frame = root.frame
        picture.layer.shadowColor = UIColor.black.cgColor
        picture.layer.shadowOpacity = 0.18
        picture.layer.shadowRadius = 10
        // Cast from the picture's trailing edge onto the conversation it is uncovering,
        // which is the edge the system's own push shadows.
        picture.layer.shadowOffset = CGSize(width: 4, height: 0)

        let shade = UIView(frame: root.frame)
        shade.backgroundColor = .black
        shade.alpha = ForwardSwipeGeometry.shade
        shade.isUserInteractionEnabled = false

        // Order matters: the shade darkens the conversation, the picture hides both.
        window.addSubview(shade)
        window.addSubview(picture)

        self.root = root
        self.picture = picture
        self.shade = shade
    }

    /// Places the arriving conversation, once the push it belongs to has been laid out.
    func arm() {
        isArmed = true
        apply()
    }

    func update(_ progress: CGFloat) {
        self.progress = min(max(progress, 0), 1)
        apply()
    }

    /// Runs the remaining distance out under its own steam.
    func settle(to target: CGFloat, velocity: CGFloat, completion: @escaping @MainActor () -> Void) {
        let duration = ForwardSwipeGeometry.settleDuration(
            from: progress,
            to: target,
            width: width,
            velocity: velocity
        )
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.update(target)
        } completion: { _ in
            MainActor.assumeIsolated(completion)
        }
    }

    /// Uncovers the screen and gives the root view back its own geometry.
    func end() {
        isFinished = true
        root?.transform = .identity
        picture.removeFromSuperview()
        shade.removeFromSuperview()
    }

    /// Applied on every change rather than once, so a stray layout pass costs one frame
    /// rather than the rest of the gesture.
    private func apply() {
        guard isArmed, !isFinished else { return }
        root?.transform = CGAffineTransform(translationX: width * ForwardSwipeGeometry.parallax * (1 - progress), y: 0)
        picture.transform = CGAffineTransform(translationX: -width * progress, y: 0)
        shade.alpha = ForwardSwipeGeometry.shade * (1 - progress)
    }
}

// MARK: - Installation

/// Puts the forward drag on the channel list's navigation controller.
///
/// The recogniser goes on that controller's view rather than on this one, and the difference
/// is load-bearing: this view lives in the sidebar, and the sidebar leaves the hierarchy the
/// instant the push happens — which is *during* the gesture. A recogniser on a view that is
/// removed mid-drag is cancelled mid-drag. The navigation controller's view is the thing the
/// push happens inside, so it is still there at the end of it.
final class SidebarForwardSwipeView: UIView, UIGestureRecognizerDelegate {
    /// What a drag would reopen, or `nil` to refuse to start one.
    var conversation: ConversationRoute?
    var open: (ConversationRoute) -> Void = { _ in }
    var close: () -> Void = {}

    private weak var host: UIView?
    private var run: ForwardSwipeRun?
    /// Whether a release is playing itself out. A drag can end long before its transition
    /// has, and the two are not the same "in progress".
    private var isSettling = false

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
        for existing in navigation.gestureRecognizers ?? [] where existing is LeftwardPanGestureRecognizer {
            navigation.removeGestureRecognizer(existing)
        }
        let pan = LeftwardPanGestureRecognizer(target: self, action: #selector(handle))
        pan.delegate = self
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

    @objc private func handle(_ pan: UIPanGestureRecognizer) {
        guard let host, let window = host.window else { return }
        switch pan.state {
        case .began:
            begin(with: host)
        case .changed:
            let translation = pan.translation(in: window).x
            run?.update(ForwardSwipeGeometry.progress(translation: translation, width: host.bounds.width))
        case .ended, .cancelled, .failed:
            let velocity = pan.velocity(in: window).x
            settle(velocity: velocity, released: pan.state == .ended)
        default:
            break
        }
    }

    private func begin(with host: UIView) {
        guard run == nil, let conversation, let run = ForwardSwipeRun(host: host) else { return }
        self.run = run
        // Instant, and hidden behind the picture taken a moment ago: the transition the
        // reader sees is the one below, not SwiftUI's.
        instantly { open(conversation) }
        // A turn later, once that push has been laid out — see ``ForwardSwipeRun/arm()``.
        DispatchQueue.main.async { run.arm() }
    }

    private func settle(velocity: CGFloat, released: Bool) {
        // The run is deliberately still held until the tidy-up: it is what
        // ``gestureRecognizerShouldBegin(_:)`` reads to refuse a second drag while this one
        // is still finishing, and there is a window during a cancelled release — after the
        // path is back but before the picture comes down — where nothing else would.
        guard let run, !isSettling else { return }
        isSettling = true
        let commits = released && ForwardSwipeGeometry.commits(progress: run.progress, velocity: velocity)
        run.settle(to: commits ? 1 : 0, velocity: velocity) { [weak self] in
            guard let self else { return }
            guard commits else {
                instantly { close() }
                // The picture stays up until the sidebar is genuinely back: a SwiftUI state
                // change is applied on a later turn, and uncovering before it lands shows a
                // frame of the conversation the reader just decided against.
                uncover(run, attempt: 0)
                return
            }
            run.end()
            release()
        }
    }

    private func uncover(_ run: ForwardSwipeRun, attempt: Int) {
        guard attempt < 6, navigationController()?.viewControllers.count != 1 else {
            run.end()
            release()
            return
        }
        DispatchQueue.main.async { [weak self] in self?.uncover(run, attempt: attempt + 1) }
    }

    private func release() {
        run = nil
        isSettling = false
    }

    private func instantly(_ change: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, change)
    }

    // MARK: - UIGestureRecognizerDelegate

    /// `override`, because `UIView` declares this too — it is the same Objective-C selector,
    /// and a plain declaration here would shadow rather than answer it.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer is LeftwardPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(recognizer)
        }
        guard conversation != nil, run == nil else { return false }
        // Only from the sidebar itself. A conversation or the Threads screen on the stack
        // means the reader is somewhere with its own leftward meanings.
        return navigationController()?.viewControllers.count == 1
    }

    /// Alongside the list's own scrolling, and nothing else.
    ///
    /// A drag has to take the touch away from whatever it began on, the way a scroll does.
    /// The first version of this claimed simultaneity with *everything*, on the reasoning
    /// that the direction gate above protected taps. It does not. That gate stops a drag
    /// beginning on a tap; nothing in it stops a tap **finishing** on a drag. Each row here
    /// is a `Button` with a custom `ButtonStyle`, so its press is SwiftUI's own gesture
    /// rather than the cell's, and a full-width row is still under the finger when it lifts
    /// three hundred points to the left — so the row navigated on top of the conversation
    /// this drag had already reopened. Measured in the harness: `BUTTON 3 fired`, between the
    /// last `changed` and the `ended` of a drag that had opened channel 7.
    ///
    /// Naming pans keeps the one exception that matters. The list's vertical scrolling has to
    /// stay alive because this recogniser cannot know the hand's direction until 10pt in, and
    /// a scroll made to wait for that would begin late every time. Everything else — the
    /// row's press, the section headings, the `+`, the context menu's long press — is now
    /// exclusive with the drag, settled in whichever direction UIKit needs: a press that has
    /// already recognised prevents the drag, and a drag that begins cancels the press.
    ///
    /// Apple documents that a `false` here is not binding, because the *other* recogniser's
    /// delegate may answer `true` and either answer is enough. So this is a measured claim
    /// rather than a guaranteed one: driven with a real finger against a row of this exact
    /// shape, the row no longer fires, while the scroll, the tap, the long press and a
    /// cancelled drag all still behave.
    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
        other is UIPanGestureRecognizer
    }
}

// MARK: - SwiftUI

/// The zero-size backing view, in the idiom the app's other UIKit reach-arounds use
/// (``WindowTint``, ``ConversationKeyboardDismissPadding``): it exists to be added to the
/// hierarchy, find what is above it, and talk to it.
struct SidebarForwardSwipe: UIViewRepresentable {
    let conversation: ConversationRoute?
    let open: (ConversationRoute) -> Void
    let close: () -> Void

    func makeUIView(context _: Context) -> SidebarForwardSwipeView {
        let view = SidebarForwardSwipeView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: SidebarForwardSwipeView, context _: Context) {
        view.conversation = conversation
        view.open = open
        view.close = close
    }
}

extension View {
    /// Drag left anywhere on the sidebar to reopen `conversation`.
    ///
    /// Anywhere, and not on the row: the row is where the conversation *is*, and a gesture
    /// that had to start there would be a second way to spell tapping it. This is a way back
    /// to where you were, so it belongs to the screen you are on.
    func sidebarForwardSwipe(
        reopening conversation: ConversationRoute?,
        open: @escaping (ConversationRoute) -> Void,
        close: @escaping () -> Void
    ) -> some View {
        background {
            SidebarForwardSwipe(conversation: conversation, open: open, close: close)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }
}
