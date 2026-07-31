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
    /// The scroll view's own takeover cancels the touch and puts the highlight out on its
    /// own, so this only covers the case that never becomes a scroll — a small movement, or a
    /// drag along an axis the list does not take. Without it a finger could wander the screen
    /// leaving one row lit behind it.
    private static let slop: CGFloat = 12

    var onChange: ((Bool) -> Void)?

    private weak var host: UIView?
    private var recognizer: MessagePressRecognizer?
    private var origin: CGPoint?
    private var isPressed = false
    private var shownAt: CFTimeInterval?
    private var pending: DispatchWorkItem?

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
        pending?.cancel()
        pending = nil
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
            origin = local
            setPressed(bounds.contains(local))
        case .moved:
            guard isPressed, let origin else { return }
            if hypot(local.x - origin.x, local.y - origin.y) > Self.slop {
                setPressed(false)
            }
        case .ended:
            origin = nil
            setPressed(false)
        }
    }

    /// Turns the press on at once and off no sooner than ``PressFeedback/minimumVisible``.
    ///
    /// The same latch every control in the app got, for the same reason: a tap can be over
    /// before a 0.16s animation has arrived anywhere, and a highlight that starts and is
    /// taken away mid-flight reads as a flicker rather than as an answer. Held here rather
    /// than in the row so the row keeps one plain `Bool` and this file owns everything about
    /// the timing of a press.
    private func setPressed(_ pressed: Bool) {
        guard pressed != isPressed else { return }
        pending?.cancel()
        pending = nil

        if pressed {
            shownAt = CACurrentMediaTime()
            isPressed = true
            onChange?(true)
            return
        }

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
}

/// A recogniser that recognises nothing.
///
/// It stays in `.possible` for the whole touch and then fails, which is what makes it
/// invisible to UIKit's arbitration: a recogniser only takes a touch away from a view when it
/// *recognises*, and this one never does. `cancelsTouchesInView` and the two `delays` flags
/// are set anyway, so that nothing here depends on that argument being right.
final class MessagePressRecognizer: UIGestureRecognizer {
    enum Phase { case began, moved, ended }

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
        report(.ended, touches)
        state = .failed
    }

    /// Reported in *window* coordinates, so a listener can convert into whatever space it
    /// occupies without knowing anything about where this recogniser lives.
    private func report(_ phase: Phase, _ touches: Set<UITouch>) {
        guard let touch = touches.first, let window = view?.window else { return }
        onTouch?(phase, touch.location(in: window))
    }
}
