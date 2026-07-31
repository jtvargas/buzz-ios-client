import SwiftUI

/// The body of ``PressFeedbackButtonStyle``, as a `View` so it can hold state.
///
/// A style cannot: `makeBody` is called to produce a view, and `@State` on the style itself
/// belongs to no view. The state it needs is the timing — when the press went on, whether the
/// release it is now handling is a *lift* or an *abandonment*, and how much of the minimum is
/// left to run before the action may fire.
///
/// Beside ``PressFeedback`` rather than inside it because that file is the *vocabulary* — the
/// numbers and what each emphasis does with them — and this is the machine that plays it.
struct PressFeedbackBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Injected by an enclosing row that has a tap of its own to arbitrate — a message row,
    /// whose tap opens the thread and fires even when the touch landed on a control inside
    /// it (``RowTapArbitration``).
    ///
    /// The row used to be told by the control's *action*, and that stopped being early enough
    /// the moment a press began holding its action back until the shrink had been seen: the
    /// action now runs up to ``PressFeedback/minimumVisible`` after the finger left, which is
    /// long after the row's own tap has come and gone. A press is the earlier signal, and it
    /// does not move when that minimum does.
    @Environment(\.claimRowTap) private var claimRowTap

    /// Whether the press is being *shown*, which is not the same as whether a finger is down.
    @State private var isShowing = false
    @State private var shownAt: Date?
    /// Whether the button's action ran during this press. Set by ``fire()``, which SwiftUI
    /// calls on touch-up-inside and never on a cancel — so it is the one signal available
    /// here that separates a finished press from one the scroll view took away.
    @State private var didTrigger = false
    @State private var release: Task<Void, Never>?
    /// The curve the *next* change of ``isShowing`` animates with. Assigned before the flag it
    /// describes, in the same turn, so one body pass sees both. `.animation(_:value:)` rather
    /// than `withAnimation` because an ambient animation from here would reach the enclosing
    /// list and animate a row arriving in a bottom-anchored scroll view.
    @State private var curve: Animation = PressFeedback.press

    var body: some View {
        Button(role: configuration.role) {
            fire()
        } label: {
            // Every adopter gets a hit area covering its whole frame; a `Text` otherwise
            // only accepts taps on its glyphs. Inside the button, because a content shape
            // applied outside it would not be the button's.
            configuration.label.contentShape(.rect)
        }
        .buttonStyle(PressStateReporter { pressed in
            // Both edges, and the second is the one that matters: a press ending is the last
            // moment before an enclosing row's own tap fires, and it happens whether this
            // press lasted a frame or a second.
            claimRowTap?()
            if pressed { show() } else { scheduleRelease() }
        })
        // Outside the button, so the scale takes the whole interactive view — its padding,
        // its hit area and its wash — and not just the glyphs of its label.
        .modifier(PressTreatment(isShowing: isShowing, emphasis: emphasis, shape: shape))
        .animation(curve, value: isShowing)
        // The other half of "immediate": SwiftUI reports this press honestly, but a scroll
        // view sits on the touch for ~150ms before SwiftUI is told about it at all. Every
        // adopter gets the delay taken off whatever it is scrolling inside — see
        // ``ScrollTouchDeliveryView``.
        .immediateScrollTouchDelivery()
        .onDisappear { release?.cancel() }
    }

    /// Runs the button's action, once the press has been on screen long enough to have been
    /// seen. Immediately when it already has been, which is every press held longer than
    /// ``PressFeedback/minimumVisible`` and every activation that never showed a press at all
    /// (a keyboard, VoiceOver).
    private func fire() {
        didTrigger = true
        guard let remaining = remainingVisible() else {
            configuration.trigger()
            return
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            configuration.trigger()
        }
    }

    private func show() {
        release?.cancel()
        release = nil
        didTrigger = false
        shownAt = .now
        curve = PressFeedback.animation(pressed: true, reduceMotion: reduceMotion)
        isShowing = true
    }

    /// Takes the press off — after the minimum if the button fired, and at once if it did not.
    ///
    /// The distinction is the owner's: a highlight that survives the finger leaving is a
    /// highlight that trails a scrolling list. A press interrupted by a scroll, by a drag off
    /// the control, or by the sidebar's forward swipe is not a release and must not be paid
    /// the minimum — it never became the press it was starting to be.
    ///
    /// Deferred by one main-actor turn because SwiftUI reports the press ending and runs the
    /// action in the same event, in no guaranteed order; a turn later, ``didTrigger`` is
    /// settled either way.
    private func scheduleRelease() {
        release?.cancel()
        release = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            if didTrigger {
                if let remaining = remainingVisible() {
                    try? await Task.sleep(for: .seconds(remaining))
                    guard !Task.isCancelled else { return }
                }
                curve = PressFeedback.animation(pressed: false, reduceMotion: reduceMotion)
            } else {
                curve = PressFeedback.cancel
            }
            isShowing = false
        }
    }

    /// How much of ``PressFeedback/minimumVisible`` this press still owes, or `nil` when it
    /// owes none.
    private func remainingVisible() -> TimeInterval? {
        guard let shownAt else { return nil }
        let remaining = PressFeedback.minimumVisible - Date.now.timeIntervalSince(shownAt)
        return remaining > 0 ? remaining : nil
    }
}

/// Reports SwiftUI's own press state upward and draws nothing.
///
/// The whole reason ``PressFeedbackBody`` can observe a finger without costing the enclosing
/// scroll view its pan: the press detection is the framework's, unchanged, and this only
/// forwards the answer.
private struct PressStateReporter: ButtonStyle {
    let onPress: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in onPress(pressed) }
    }
}
