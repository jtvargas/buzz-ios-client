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
///    screen the window cannot take a touch at all.
@MainActor
final class InAppNotificationWindowController {
    private var window: PassthroughWindow?

    /// Puts `layer` on screen in the overlay window, creating it on the first banner.
    ///
    /// - Parameter scene: the scene the app is actually in, read from a view that is in it —
    ///   never guessed from `UIApplication.shared.connectedScenes`, which has no answer during
    ///   a scene transition.
    func present(_ layer: InAppNotificationLayer, in scene: UIWindowScene, isInteractive: Bool) {
        let window = window ?? makeWindow(in: scene)
        (window.rootViewController as? UIHostingController<InAppNotificationLayer>)?.rootView = layer
        window.isUserInteractionEnabled = isInteractive
    }

    private func makeWindow(in scene: UIWindowScene) -> PassthroughWindow {
        let made = PassthroughWindow(windowScene: scene)
        let host = UIHostingController(rootView: InAppNotificationLayer(notification: nil))
        // Clear on both, or the window paints a black sheet over the app.
        host.view.backgroundColor = .clear
        made.rootViewController = host
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
        return made
    }
}

/// A window that only takes the touches its content actually wants.
private final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        // The hosting controller's own view means the point missed everything drawn in it.
        return hit === rootViewController?.view ? nil : hit
    }
}

/// What the overlay window draws: the banner, or nothing, pinned to the top.
struct InAppNotificationLayer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var notification: InAppNotification?
    var open: (InAppNotification) -> Void = { _ in }
    var dismiss: () -> Void = {}

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

/// Carries the current banner into the overlay window, and carries the app's scene back out.
///
/// A representable rather than a reach into `UIApplication`: this view is *in* the scene the
/// banner belongs to, so `window?.windowScene` is the answer rather than a guess. It draws
/// nothing and takes no touches — it exists to be somewhere in the hierarchy.
struct InAppNotificationWindowPresenter: UIViewRepresentable {
    let notification: InAppNotification?
    let open: (InAppNotification) -> Void
    let dismiss: () -> Void

    func makeCoordinator() -> InAppNotificationWindowController {
        InAppNotificationWindowController()
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isHidden = true
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // `window` is nil for the first update, before this view is in the hierarchy. Nothing
        // to do then: a banner cannot exist that early, and the next update has a scene.
        guard let scene = uiView.window?.windowScene else { return }
        context.coordinator.present(
            InAppNotificationLayer(notification: notification, open: open, dismiss: dismiss),
            in: scene,
            isInteractive: notification != nil
        )
    }
}
