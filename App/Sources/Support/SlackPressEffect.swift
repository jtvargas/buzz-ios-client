import SwiftUI

/// The press treatment as a **standalone** modifier and container, for a view that is not
/// already a `Button`.
///
/// # Why this is four lines and not a second implementation
///
/// The owner asked for an API shaped like `SlackPressable { … } content: { … }` or
/// `.slackPressEffect { … }`, and the temptation is to build the touch handling behind it from
/// scratch — a `DragGesture(minimumDistance: 0)`, a `@GestureState`, an
/// `onLongPressGesture(onPressingChanged:)`. **Every one of those would break scrolling.** A
/// gesture that tracks has claimed the touch away from the scroll view it sits inside, and this
/// app has shipped a conversation that could not be scrolled at all, twice, that exact way.
///
/// So this is a `Button` wearing ``PressFeedbackButtonStyle``, which is the machine that
/// already answers every requirement behind the request:
///
/// - **touch-down, not tap-completion** — ``ScrollTouchDeliveryView`` strips
///   `delaysContentTouches` off every scrolling ancestor, so SwiftUI is told about the finger
///   when it lands rather than ~150ms later;
/// - **the action is independent of the animation** — ``PressFeedbackBody/fire()`` calls
///   `trigger()` with nothing in front of it, and the release plays *over* whatever it started;
/// - **cancel and drag-out** — `PrimitiveButtonStyleConfiguration.trigger()` is called on
///   touch-up-inside and never on a cancel, which is the only signal that separates a lift from
///   the scroll view taking the touch; an abandoned press comes off on ``PressFeedback/cancel``,
///   a sixth of the release;
/// - **interruptible and continuous** — the curves are retargetable springs, so a second tap
///   during a release picks the control up from where it is;
/// - **VoiceOver, disabled state, roles** — inherited from `Button`, which is the other half of
///   why a hand-rolled `UIControl` bridge would be a downgrade rather than an upgrade.
///
/// UIKit bridging is used for exactly one thing — the touch *delay*, which SwiftUI cannot reach
/// — and for nothing else. That is the owner's own condition: bridge only where SwiftUI cannot
/// provide reliable touch-down, cancellation or drag-exit. It can provide the last two.
extension View {
    /// Presses this view like a control: a 2.5% shrink in on touch-down, the accent washed
    /// inside its shape, and the action on the lift.
    ///
    /// For something that is not already a `Button`. Anything that *is* one should carry
    /// `.buttonStyle(.hivePress(…))` directly rather than being wrapped in a second button.
    ///
    /// - Parameters:
    ///   - emphasis: How much of the treatment to take. See
    ///     ``PressFeedbackButtonStyle/Emphasis``.
    ///   - shape: The shape the wash is drawn in. A wash in the wrong shape is more visible
    ///     than no wash at all, so a capsule chip or a rounded card should name its own.
    ///   - action: Run on touch-up-inside, immediately, and never on a cancel.
    func slackPressEffect(
        _ emphasis: PressFeedbackButtonStyle.Emphasis = .control,
        in shape: some Shape = .rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous),
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { self }
            .buttonStyle(PressFeedbackButtonStyle(emphasis, in: shape))
    }
}

/// The same treatment as a container, for a call site that reads better with the action first.
///
/// ```swift
/// SlackPressable {
///     performAction()
/// } content: {
///     ComponentView()
/// }
/// ```
///
/// Identical to ``SwiftUI/View/slackPressEffect(_:in:action:)`` in every respect — see that
/// method, and ``PressFeedbackButtonStyle``, for why neither of them handles a touch itself.
struct SlackPressable<Content: View>: View {
    private let action: () -> Void
    private let emphasis: PressFeedbackButtonStyle.Emphasis
    private let shape: AnyShape
    private let content: () -> Content

    init(
        _ emphasis: PressFeedbackButtonStyle.Emphasis = .control,
        in shape: some Shape = .rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous),
        action: @escaping () -> Void,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.emphasis = emphasis
        self.shape = AnyShape(shape)
        self.action = action
        self.content = content
    }

    var body: some View {
        Button(action: action) { content() }
            .buttonStyle(PressFeedbackButtonStyle(emphasis, in: shape))
    }
}
