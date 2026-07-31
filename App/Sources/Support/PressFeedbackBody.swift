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

    /// Injected by an enclosing row that has a tap of its own to arbitrate — a message row,
    /// whose tap opens the thread and fires even when the touch landed on a control inside
    /// it (``RowTapArbitration``).
    ///
    /// Claimed from ``fire()``, which is to say from the *activation* — never from the press.
    /// It was claimed on both edges of the press for one round, while the action was being
    /// held back behind the animation and so was no longer early enough to claim for itself.
    /// That was wrong in a way worth writing down: a press that ends in a *cancel* — a finger
    /// that lands on a reaction chip and then scrolls away — reports exactly the same
    /// `isPressed` edge as a lift, so the row's tap was being suppressed by a control that
    /// never ran, and a genuine tap arriving within ``RowTapArbitration/window`` silently did
    /// not open the thread. With the action immediate again the activation is the earliest
    /// *and* the only correct signal.
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
            if pressed { show() } else { scheduleRelease() }
        })
        // Outside the button, so the treatment covers the whole interactive view — its
        // padding and its hit area — and not just the glyphs of its label.
        .modifier(PressTreatment(isShowing: isShowing, emphasis: emphasis, shape: shape))
        .animation(curve, value: isShowing)
        // The other half of "immediate": SwiftUI reports this press honestly, but a scroll
        // view sits on the touch for ~150ms before SwiftUI is told about it at all. Every
        // adopter gets the delay taken off whatever it is scrolling inside — see
        // ``ScrollTouchDeliveryView``.
        .immediateScrollTouchDelivery()
        .onDisappear { release?.cancel() }
    }

    /// Runs the button's action, immediately, and records that this press ended in one.
    ///
    /// Nothing here waits. The release plays *over* whatever the action starts, which is the
    /// whole point: a push, a sheet or a send happens at the speed of the finger, and the
    /// control settles back behind it. This method held the action back by up to
    /// ``PressFeedback/minimumVisible`` for one round so the press could be seen before the
    /// screen it was drawn on was replaced, and the owner's report on that build was that the
    /// entire app now felt delayed. He was right, and the honest reading is that the earlier
    /// complaint it was answering had a different cause — ``ScrollTouchDeliveryView`` — which
    /// this was standing in for.
    ///
    /// ``claimRowTap`` is called from here rather than from the press for the same reason it
    /// is called at all: it must fire when a control *acts*, and a cancelled press is not an
    /// act. It runs before the action so an enclosing row's deferred tap, one main-actor turn
    /// behind, always sees the claim.
    private func fire() {
        didTrigger = true
        claimRowTap?()
        configuration.trigger()
    }

    private func show() {
        release?.cancel()
        release = nil
        didTrigger = false
        shownAt = .now
        curve = PressFeedback.animation(pressed: true)
        isShowing = true
    }

    /// Takes the press off — after the minimum if the button fired, and at once if it did not.
    ///
    /// The action has already run by the time this is reached; what is being scheduled is only
    /// how the control gets back to rest.
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
                curve = PressFeedback.animation(pressed: false)
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
