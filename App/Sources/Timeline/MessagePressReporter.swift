import SwiftUI
import UIKit

/// Reports a finger arriving on a message and leaving it, without ever taking the touch.
///
/// # Why this is UIKit and not a gesture
///
/// Every SwiftUI way of observing a touch going down — `DragGesture(minimumDistance: 0)`,
/// `onLongPressGesture(onPressingChanged:)`, `@GestureState` hung off a long press — works by
/// making a *gesture* start tracking at touch-down. A gesture that is tracking has claimed
/// the touch, and the scroll view underneath never receives it. Shipped once, measured on a
/// device: a 45% drag beginning on a message moved the conversation by 0.0pt. The list was
/// not slow, it was dead, and the row lit up correctly the whole time — which is why it got
/// past a review that read the diff instead of dragging it.
///
/// A `UIGestureRecognizer` that never leaves `.possible` has the opposite property. It is
/// delivered every touch of the sequence and claims none of them: it cannot delay the scroll
/// view's pan, cannot cancel it, and cannot win against it. It is a listener wearing a
/// recogniser's clothes, and it is the only construction here that observes a press without
/// costing the reader the gesture they use most.
///
/// The scroll view's pan cancels the touches in its subviews the moment it takes over, which
/// arrives here as ``Phase/ended`` — so a press that turns into a scroll puts its own
/// highlight out, with nothing in this file having to notice that a scroll began.
extension View {
    /// Reports whether a finger is down inside this view's bounds.
    ///
    /// `isEnabled` because the reporter is only ever wanted where a press *means* something:
    /// on the Threads screen a row presents no sheet, so a highlight there would announce an
    /// action that is not coming.
    func messagePressReporter(isEnabled: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        overlay {
            if isEnabled {
                MessagePressReporter(onChange: onChange)
                    // Load-bearing: this view must never be in the way of anything. It is a
                    // vantage point, not a target — it reads its own frame and nothing else.
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct MessagePressReporter: UIViewRepresentable {
    let onChange: (Bool) -> Void

    func makeUIView(context: Context) -> MessagePressReporterView {
        let view = MessagePressReporterView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ view: MessagePressReporterView, context: Context) {
        view.onChange = onChange
    }

    static func dismantleUIView(_ view: MessagePressReporterView, coordinator: ()) {
        view.detach()
    }
}

/// The vantage point: a view that occupies the row's own frame and answers "is the finger in
/// here", by watching a recogniser installed on the scrolling view above it.
final class MessagePressReporterView: UIView {
    /// How far a finger may travel and still be pressing *this* row.
    ///
    /// UIKit's own allowance for a long press, and small enough to answer the owner's rule:
    /// *the highlight must disappear as soon as the finger moves.*
    private static let slop: CGFloat = 10

    /// How long a finger must rest before the message it is on lights up.
    ///
    /// `UIScrollView.delaysContentTouches` in miniature, and for its reason: a flick that
    /// starts a scroll begins as a touch on a row, so a row that lights at touch-down flashes
    /// under every scroll the reader makes. A tenth of a second is longer than a flick spends
    /// standing still and shorter than a deliberate press — and a tap that ends *inside* the
    /// delay still lights up, on release, exactly as a table cell does. So nothing is lost:
    /// the only press this refuses to draw is the one that was already becoming a scroll.
    private static let armDelay: TimeInterval = 0.1

    /// Where a touch is in its life on this row.
    private enum Stage {
        /// No touch, or one this row has given up on.
        case idle
        /// A finger is down and has not moved; the highlight is waiting out ``armDelay``.
        case arming
        /// The highlight is on screen.
        case showing
    }

    var onChange: ((Bool) -> Void)?

    private weak var host: UIView?
    private var recognizer: MessagePressRecognizer?
    private var origin: CGPoint?
    private var stage: Stage = .idle
    private var isPressed = false
    private var shownAt: CFTimeInterval?
    private var pending: DispatchWorkItem?
    private var arming: DispatchWorkItem?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { detach() } else { attach() }
    }

    /// Installs on the nearest scrolling ancestor, falling back to the window.
    ///
    /// The scroll view rather than the window because that is the smallest thing that sees
    /// every touch this row can receive: a touch that never reaches the list is not a press
    /// on a message, and filtering those out here costs nothing later.
    private func attach() {
        guard recognizer == nil else { return }
        guard let host = enclosingScrollView() ?? window else { return }
        let recognizer = MessagePressRecognizer()
        recognizer.onTouch = { [weak self] phase, point in
            self?.report(phase, at: point)
        }
        host.addGestureRecognizer(recognizer)
        self.recognizer = recognizer
        self.host = host
    }

    func detach() {
        if let recognizer {
            host?.removeGestureRecognizer(recognizer)
        }
        recognizer = nil
        host = nil
        origin = nil
        stage = .idle
        pending?.cancel()
        pending = nil
        arming?.cancel()
        arming = nil
        // Straight off, past the latch: the row is going away, and a delayed callback into a
        // view that has left the hierarchy would light whatever is recycled into its place.
        if isPressed {
            isPressed = false
            onChange?(false)
        }
    }

    private func enclosingScrollView() -> UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }

    private func report(_ phase: MessagePressRecognizer.Phase, at windowPoint: CGPoint) {
        guard window != nil else { return }
        let local = convert(windowPoint, from: nil)
        switch phase {
        case .began:
            guard bounds.contains(local) else { return }
            origin = local
            arm()
        case .moved:
            guard stage != .idle, let origin else { return }
            // The owner's rule, and the one this file exists to keep: *as soon as the finger
            // moves*. Before the delay it means the press is never drawn; after it, it means
            // the press comes off without waiting out its minimum, because a press that turns
            // into a drag was never a press.
            if hypot(local.x - origin.x, local.y - origin.y) > Self.slop {
                abandon()
            }
        case .ended:
            // A lift. If the delay has not run out yet the touch was a quick tap, which is a
            // press worth drawing — so it is drawn now, on release, and held for its minimum
            // the way a table cell flashes for a tap too fast to have highlighted.
            if stage == .arming { light() }
            origin = nil
            stage = .idle
            fade()
        case .cancelled:
            // The scroll view taking the touch arrives here, and so does a call, a
            // notification, and the sidebar's forward swipe. None of them is a release.
            abandon()
        }
    }

    /// Starts the clock on a press without drawing one. See ``armDelay``.
    private func arm() {
        pending?.cancel()
        pending = nil
        arming?.cancel()
        stage = .arming
        let work = DispatchWorkItem { [weak self] in
            guard let self, stage == .arming else { return }
            light()
        }
        arming = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.armDelay, execute: work)
    }

    /// Puts the highlight on and records when, so ``fade()`` knows what it still owes.
    private func light() {
        arming?.cancel()
        arming = nil
        stage = .showing
        guard !isPressed else { return }
        shownAt = CACurrentMediaTime()
        isPressed = true
        onChange?(true)
    }

    /// Takes the highlight off no sooner than ``PressFeedback/minimumVisible``.
    ///
    /// The same latch every control in the app got, for the same reason: a tap can be over
    /// before the curve that draws the press has arrived anywhere, and a highlight that starts
    /// and is taken away mid-flight reads as a flicker rather than as an answer. Only a lift
    /// is paid it — see ``abandon()``.
    private func fade() {
        pending?.cancel()
        pending = nil
        guard isPressed else { return }

        let remaining = PressFeedback.minimumVisible - (CACurrentMediaTime() - (shownAt ?? 0))
        guard remaining > 0 else {
            isPressed = false
            onChange?(false)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            isPressed = false
            onChange?(false)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    /// Gives up on this touch: no highlight if one was still coming, and no minimum if one is
    /// already on screen.
    private func abandon() {
        arming?.cancel()
        arming = nil
        pending?.cancel()
        pending = nil
        origin = nil
        stage = .idle
        guard isPressed else { return }
        isPressed = false
        onChange?(false)
    }
}

/// A recogniser that recognises nothing.
///
/// It stays in `.possible` for the whole touch and then fails, which is what makes it
/// invisible to UIKit's arbitration: a recogniser only takes a touch away from a view when it
/// *recognises*, and this one never does. `cancelsTouchesInView` and the two `delays` flags
/// are set anyway, so that nothing here depends on that argument being right.
final class MessagePressRecognizer: UIGestureRecognizer {
    /// A lift and a cancel are separate phases because they mean opposite things to a
    /// highlight: one finished the press it was drawing and the other took it away.
    enum Phase { case began, moved, ended, cancelled }

    var onTouch: ((Phase, CGPoint) -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    convenience init() {
        self.init(target: nil, action: nil)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.began, touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.moved, touches)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.ended, touches)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        report(.cancelled, touches)
        state = .failed
    }

    /// Reported in *window* coordinates, so a listener can convert into whatever space it
    /// occupies without knowing anything about where this recogniser lives.
    private func report(_ phase: Phase, _ touches: Set<UITouch>) {
        guard let touch = touches.first, let window = view?.window else { return }
        onTouch?(phase, touch.location(in: window))
    }
}
