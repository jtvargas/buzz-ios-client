import SwiftUI
import UIKit

/// The banner's own window, so it draws above everything the app can present.
///
/// # Why a window and not an overlay
///
/// It was an `.overlay` on the `TabView`, which put it inside the app's own view tree — and a
/// sheet, a `fullScreenCover` and Quick Look are all presented in a *separate* container above
/// that tree. So a message arriving while the reader had a PDF open drew the card underneath
/// the preview and took it away again five seconds later, which reads as "sometimes I get a
/// notification and sometimes I do not". No z-index, ordering or presentation-detent change
/// reaches that: only something outside the presenting hierarchy is above a presentation, and
/// on iOS that means another window. It is what the system does with its own banners.
///
/// Nothing about the card changes — it is the same SwiftUI view with the same gestures, and
/// the app keeps using native sheets and native Quick Look underneath it.
///
/// # Why the model calls this directly, and no view does
///
/// Handing the card over used to be the job of ``InAppNotificationScenePresenter/updateUIView``.
/// That works right up until it is needed: **UIKit detaches the presenting view tree from the
/// window once a full-screen modal has finished animating in, and SwiftUI then stops running
/// body and `updateUIView` for that tree entirely, flushing only on dismiss.** Quick Look is
/// presented full screen. So with a PDF open the message landed, the model raised a banner, and
/// nothing downstream of a view update ran — no card and, because the arrival haptic was fired
/// from a `.task(id:)`, no buzz either. It looked like two bugs and was one.
///
/// Measured rather than reasoned: a driven fixture (`-fixtureInAppNotificationOverPreview`)
/// raised a banner behind a real preview and the update pass arrived fifteen seconds later, at
/// the instant Done was tapped.
///
/// So this object is driven from ``InAppNotificationModel``, which is a plain observable with
/// no view lifetime of its own. What is left for a view is the one thing a view is actually
/// needed for: saying which scene the app is in. See ``InAppNotificationScenePresenter``.
///
/// # Not swallowing the app
///
/// A full-screen window on top of everything is a full-screen touch target unless it is told
/// otherwise, and getting that wrong makes the whole app unresponsive. Two independent
/// guards, because one of them depends on SwiftUI's hit-testing behaviour and the other does
/// not:
///
/// 1. ``PassthroughWindow`` refuses any touch that lands on the hosting controller's own view
///    rather than on something inside it — the standard overlay-window idiom.
/// 2. The window's `isUserInteractionEnabled` is **false whenever no banner is up**, which is
///    almost all of the time. That one needs nothing to be true about SwiftUI: with no card on
///    screen the window cannot take a touch at all. It is derived from the card here rather
///    than set by callers, so the two cannot drift apart.
@MainActor
final class InAppNotificationWindowController {
    private var window: PassthroughWindow?
    /// Held so the root view can be replaced directly even while the app's own presenting
    /// hierarchy is detached beneath this window.
    private var host: UIHostingController<InAppNotificationLayer>?

    /// The scene the app is in, remembered from the last time a view could see one.
    ///
    /// Remembered rather than read on demand, because the moment this window matters most is
    /// exactly the moment no view in the app can answer: a detached tree's `window` is `nil`,
    /// so a lookup at present-time would fail for every banner raised over a preview. It is
    /// also why `UIApplication.shared.connectedScenes` is only a last-chance fallback here:
    /// it has no answer during a transition and can name the wrong scene on iPad.
    ///
    /// Weak because the scene owns the window rather than the other way round, and a scene
    /// that goes away must not be held open by this.
    private weak var scene: UIWindowScene?

    /// Remembers the scene while a view can see one. Called on every update of the presenter,
    /// so the answer is refreshed whenever the app is not covered — including after a scene
    /// change, and at launch long before any banner exists.
    func observe(_ scene: UIWindowScene?) {
        guard let scene else {
            InAppNotificationDiagnostics.record(
                "scene transition=ignored-nil remembered=\(self.scene != nil)"
            )
            return
        }
        let transition = if self.scene == nil {
            "nil-to-scene"
        } else if self.scene === scene {
            "same-scene"
        } else {
            "scene-to-scene"
        }
        InAppNotificationDiagnostics.record("scene transition=\(transition)")
        self.scene = scene
    }

    /// Draws `notification`, or nothing, in the overlay window — creating it on the first card.
    ///
    /// The presenter remains the authoritative scene source. If that weak reference has died,
    /// a foreground scene is recovered as a last chance; without either, the drop is recorded.
    func show(
        _ notification: InAppNotification?,
        open: @escaping (InAppNotification) -> Void,
        dismiss: @escaping () -> Void
    ) {
        if window == nil, scene == nil {
            scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            InAppNotificationDiagnostics.record(
                "scene fallback=\(scene == nil ? "not-found" : "foreground-active")"
            )
        }
        guard let window = window ?? scene.map(makeWindow(in:)) else {
            InAppNotificationDiagnostics.record(
                "show outcome=dropped-no-scene notification=\(notification?.id ?? "nil")"
            )
            return
        }
        // Name whose frames count from here on; the reset comes with it. The card being
        // replaced keeps laying out while it animates away, so its reports outlive this call
        // and would otherwise overwrite that reset — see ``PassthroughWindow/currentCardID``.
        let card = notification?.id
        window.currentCardID = card
        host?.rootView = InAppNotificationLayer(
            notification: notification,
            open: open,
            dismiss: dismiss,
            reportFrame: { [weak window] frame in window?.report(frame, from: card) }
        )
        window.isUserInteractionEnabled = notification != nil
    }

    /// Takes the window down with the view that owned it.
    ///
    /// Necessary rather than tidy: a visible `UIWindow` is retained by its scene, not by this
    /// object, so letting the controller go does **not** take the window with it. Without this
    /// a community switch or a sign-out — both of which rebuild the host — would leave the old
    /// window on the scene and stand a second one on top of it.
    func teardown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        host = nil
    }

    private func makeWindow(in scene: UIWindowScene) -> PassthroughWindow {
        let made = PassthroughWindow(windowScene: scene)
        let card = UIHostingController(rootView: InAppNotificationLayer(notification: nil))
        // Clear on both, or the window paints a black sheet over the app.
        card.view.backgroundColor = .clear
        made.rootViewController = card
        made.backgroundColor = .clear
        // Above alerts, which is where a notification belongs: an alert is something the
        // reader is answering, and a banner that hid behind one would be gone by the time
        // they finished.
        made.windowLevel = .alert + 1
        // `isHidden = false` and not `makeKeyAndVisible()`. Taking key status away from the
        // app's own window is how an overlay window steals the keyboard and first responder
        // from whatever the reader was typing in.
        made.isHidden = false
        window = made
        host = card
        return made
    }
}

/// A window that only takes the touches that land on the card itself.
///
/// # Why the rule is a rectangle and not a view identity
///
/// The obvious spelling — reject the hit when it is the hosting controller's own view — cannot
/// work here, because a full-screen `_UIHostingView` answers with *itself* for a point on the
/// card and for empty space alike. Measured on device-class simulator: (200, 90) over the card
/// and (200, 600) over nothing both reported `_UIHostingView<InAppNotificationLayer>`. So that
/// rule either rejects every tap on the banner or hands the window the whole screen.
///
/// So the geometry is carried explicitly. ``InAppNotificationLayer`` reports the card's frame
/// as it lays out, and this window admits touches inside that rectangle and nothing else. The
/// hosting view stays full-screen so SwiftUI owns the top-edge safe-area layout; window level,
/// not the hosting view's size, is what keeps the banner above presented content.
private final class PassthroughWindow: UIWindow {
    /// Where the card is, in this window's coordinates. `.zero` whenever no card is up, which
    /// makes the empty case reject by the same rule rather than by a second one.
    private(set) var cardFrame: CGRect = .zero

    /// Which card's reports are believed. Set before the root view is replaced, and it is the
    /// only thing that makes `.zero` stick.
    ///
    /// A removal is animated, so the outgoing card lays out for another ~0.4s *after* the
    /// controller has already reset the frame — and every one of those passes reported its
    /// new position, the last of them off the top of the screen. The window was therefore
    /// left believing a card sat at roughly `(12, -34, 416, 96)` forever: harmless for touches
    /// (`isUserInteractionEnabled` is false with no card), but it made `hitTest` log a line
    /// for every touch anywhere in the app, which is exactly what its own guard exists to
    /// prevent, and it filled the bounded diagnostics buffer with them.
    ///
    /// The id is captured in the reporting closure when the card is handed over, so a
    /// departing card carries the id it was shown with and a nil `currentCardID` — or the id
    /// of the card that replaced it — rejects it. Comparing against the *current* notification
    /// is what a frame-shape or an animation-completion test cannot do: a departing card's
    /// frames are legitimate geometry, just not for the card that is up now.
    ///
    /// Clearing the frame is derived from this rather than done beside it, so the two cannot
    /// drift — and only on an actual change of card. Zeroing on every assignment would break
    /// a repeat `show` of the *same* notification: the banner carries `.id(notification.id)`,
    /// so an unchanged id rebuilds nothing, `onChange` sees no new frame and never re-reports,
    /// and the card would be left on screen with an empty rectangle — untappable.
    var currentCardID: String? {
        didSet {
            guard oldValue != currentCardID else { return }
            cardFrame = .zero
        }
    }

    /// Takes a laid-out frame from `card`, and ignores it unless that card is the one up now.
    func report(_ frame: CGRect, from card: String?) {
        guard card == currentCardID else { return }
        cardFrame = frame
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard cardFrame.contains(point) else {
            // Only recorded while a card is actually up. This override runs before any
            // `super` call, so `isUserInteractionEnabled = false` does not spare it: with no
            // banner on screen it is still asked about every touch anywhere in the app.
            // Logging those would bury the handful of lines this file exists to capture —
            // and it is the 256 KB cap's truncation that would throw them away.
            if cardFrame != .zero {
                InAppNotificationDiagnostics.record(
                    "hitTest outcome=passthrough point=\(point) cardFrame=\(cardFrame)"
                )
            }
            return nil
        }
        InAppNotificationDiagnostics.record(
            "hitTest outcome=admit point=\(point) cardFrame=\(cardFrame)"
        )
        return super.hitTest(point, with: event)
    }
}

/// What the overlay window draws: the banner, or nothing, pinned to the top.
struct InAppNotificationLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var notification: InAppNotification?
    var open: (InAppNotification) -> Void = { _ in }
    var dismiss: () -> Void = {}
    /// Hands the card's laid-out frame to the window, which is the only thing that knows which
    /// touches belong to the banner. See ``PassthroughWindow``.
    var reportFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            if let notification {
                InAppNotificationBanner(notification: notification) {
                    open(notification)
                } dismiss: {
                    dismiss()
                }
                .id(notification.id)
                .frame(maxWidth: 520)
                .background {
                    GeometryReader { proxy in
                        // `.global` in a window-backed hierarchy is that window's own
                        // coordinate space, which is the space `hitTest` is asked about.
                        Color.clear.onChange(of: proxy.frame(in: .global), initial: true) { _, frame in
                            reportFrame(frame)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .safeAreaPadding(.top, 8)
                .transition(transition)
            }
            Spacer(minLength: 0)
        }
        .animation(animation, value: notification?.id)
    }

    /// Bounce carries the overshoot: the card travels a little past where it lands and settles
    /// back, which is the system banner's own entrance and the reason it reads as a physical
    /// thing dropping in rather than a rectangle being switched on.
    private var animation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.22)
    }

    /// Insertion also grows the last 3% into place, anchored at the top so the card appears to
    /// come *from* the edge it is sliding out of. Removal deliberately does not shrink — a
    /// dismissal should leave immediately, not perform.
    private var transition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: .top)
                .combined(with: .opacity)
                .combined(with: .scale(scale: 0.97, anchor: .top)),
            removal: .move(edge: .top).combined(with: .opacity)
        )
    }
}

/// Carries the app's scene out to the overlay window, and takes that window down again.
///
/// Two jobs, and deliberately not a third — the card itself goes straight from the model to
/// ``InAppNotificationWindowController``, for the reason set out there.
///
/// A representable rather than a reach into `UIApplication`: this view is *in* the scene the
/// banner belongs to, so `window?.windowScene` is the answer rather than a guess. It draws
/// nothing and takes no touches — it exists to be somewhere in the hierarchy.
///
/// `controller` is passed in rather than made in `makeCoordinator` because the model owns it
/// and calls it; this view only needs to be handed the same object, so that `dismantleUIView`
/// reaches the window that is actually up.
///
/// # Why the scene is read in `didMoveToWindow` and not in `updateUIView`
///
/// Because `updateUIView` runs exactly once here, and it is the wrong once. This view's only
/// input is a reference that never changes, so after the first pass SwiftUI has no reason to
/// update it again — and on that first pass the view has been made but not yet added to a
/// window, so the scene is `nil`. Reading it there yields a controller that never learns where
/// it is and silently draws nothing, which is the shape of the bug this file exists to fix
/// wearing different clothes. `didMoveToWindow` is UIKit telling us the answer changed, and
/// owes nothing to SwiftUI's update scheduling.
struct InAppNotificationScenePresenter: UIViewRepresentable {
    let controller: InAppNotificationWindowController

    func makeCoordinator() -> InAppNotificationWindowController {
        controller
    }

    func makeUIView(context: Context) -> UIView {
        let view = SceneReportingView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        // Captured directly rather than through `context.coordinator` inside the closure, so
        // the view holds the controller and not the SwiftUI context.
        let controller = context.coordinator
        view.report = { scene in
            MainActor.assumeIsolated { controller.observe(scene) }
        }
        return view
    }

    func updateUIView(_: UIView, context _: Context) {}

    static func dismantleUIView(_: UIView, coordinator: InAppNotificationWindowController) {
        coordinator.teardown()
    }
}

/// Reports the scene it lands in, every time that changes.
///
/// Nil when a full-screen presentation detaches the tree, which ``InAppNotificationWindowController/observe(_:)``
/// deliberately ignores — the last real scene stays remembered, and that is what lets a banner
/// be raised over a preview.
private final class SceneReportingView: UIView {
    var report: ((UIWindowScene?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report?(window?.windowScene)
    }
}
