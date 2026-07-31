import SwiftUI

/// The numbers behind every control's answer to a finger.
///
/// They live here rather than as literals in each style because the whole point of the
/// treatment is that it is *one* treatment: a chip that shrinks to 0.96 beside a card that
/// shrinks to 0.92 reads as two apps. The same reasoning as ``MessageRowMetrics`` — values
/// agreeing in eleven files is an accident waiting to be changed in one of them.
///
/// # The shape of the gesture
///
/// Three curves, not two, and the third is the one this file was missing when it first
/// shipped. Down is a fast ease-out, because a press has to answer *immediately*. Up is a
/// spring, because the release is the moment the control is allowed to feel physical. And a
/// press that is **abandoned** — the finger moved, the scroll view took the touch — comes off
/// in a sixth of the time either of those take, with no latch in front of it: a highlight
/// that trails a scrolling finger is the single most common way this treatment reads as
/// broken, and it is not a release, so it must not animate like one.
enum PressFeedback {
    /// What a pressed control shrinks to.
    ///
    /// The shallow end of the range a touch can register at all: at 0.95 and below the label
    /// visibly re-lays out at the accessibility text sizes.
    static let pressedScale: CGFloat = 0.965

    /// The wash a pressed control draws behind itself, over whatever it is sitting on.
    ///
    /// The accent at 0.14, which is not a taste call — it is
    /// ``ChannelListView/resumeMark(isResumable:)``, the mark on the conversation you were
    /// last in, to the number. The owner asked for the two to be the same thing, and they
    /// now share a colour, an opacity, a corner and an inset: one highlight in the app,
    /// saying *this one*, whether it is marking a place or answering a finger.
    static let pressedFill: Double = 0.14

    /// The colour of that wash. Named here so the sidebar's mark and every press in the app
    /// cannot drift apart without this line changing.
    static let fillColor = Color.hiveAccent

    /// How long a press stays on screen at the very least, **and** how long the control's own
    /// action waits behind it.
    ///
    /// Two rules with one number, deliberately. The first cut of this treatment "didn't
    /// animate" because `isPressed` follows the finger exactly and a tap is shorter than the
    /// curve that draws it. The second cut fixed that and was still reported as
    /// imperceptible, for the other half of the same reason: the *action* fired on lift, so
    /// the screen the press was drawn on was already being replaced while the shrink was
    /// arriving. A press is worth seeing only if there is something left to see it on — so the
    /// press plays through, and the action runs when it has.
    ///
    /// Past the ease-out with room to spare, and short enough that a double tap still reads
    /// as two.
    static let minimumVisible: TimeInterval = 0.22

    /// How far a full-width row's wash is inset, horizontally and vertically.
    ///
    /// ``ChannelListView/resumeMark(isResumable:)``'s own padding. A row's highlight stopping
    /// short of both screen edges is what makes it read as *this row* rather than as a band
    /// laid across the list.
    static let rowInset = (horizontal: CGFloat(8), vertical: CGFloat(1))

    /// What a pressed control with no shape of its own fades to — the sender's name and
    /// avatar on a message, which sit directly on the conversation.
    static let pressedDim: Double = 0.55

    /// The corner radius the wash is drawn with when a control does not name its own shape.
    /// The sidebar mark's, and `.continuous` like it.
    static let cornerRadius: CGFloat = 10

    /// How long the press takes to land, how long the release takes to settle, and how long
    /// an abandoned press takes to disappear.
    ///
    /// `pressDuration` is well inside ``minimumVisible`` on purpose: the shrink has to *finish*
    /// and be held for a moment, not merely be under way, before the action runs.
    static let pressDuration: TimeInterval = 0.12
    static let releaseDuration: TimeInterval = 0.2
    /// Near enough to instant to be gone within two frames of the finger moving.
    static let cancelDuration: TimeInterval = 0.06

    /// Down: fast where the finger is.
    static let press = Animation.easeOut(duration: pressDuration)

    /// Up: snappy, with the small overshoot that reads as physical.
    static let release = Animation.spring(response: releaseDuration, dampingFraction: 0.7)

    /// Abandoned: off the screen before the finger has travelled a centimetre.
    static let cancel = Animation.easeOut(duration: cancelDuration)

    /// The animation for a transition *into* `isPressed`.
    ///
    /// Reduce Motion takes the spring off the release — an overshoot is exactly the
    /// "unnecessary movement" the setting exists to decline — and leaves the wash, which is
    /// the part that says the control was hit.
    static func animation(pressed: Bool, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return press }
        return pressed ? press : release
    }

    /// What a pressed control of this emphasis shrinks to.
    ///
    /// Every emphasis shrinks, including a full-width row. It did not, and the reasoning was
    /// that a row pulling away from both screen edges reads as a card lifting off the list.
    /// The owner overruled it from a device with the observation that settles it: a row is the
    /// thing he presses most, and a treatment his most common target opts out of is a
    /// treatment he cannot see. Only Reduce Motion declines the movement now.
    static func scale(for _: PressFeedbackButtonStyle.Emphasis, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : pressedScale
    }

    /// What a pressed control of this emphasis fades to. Only the emphasis that draws
    /// nothing behind itself dims; the others say it with the wash.
    static func dim(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        emphasis == .inline ? pressedDim : 1
    }

    /// The wash a pressed control of this emphasis draws in its own shape. Zero for the
    /// emphasis that draws nothing.
    static func fill(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        emphasis == .inline ? 0 : pressedFill
    }
}

/// Slack's press treatment, in the three shapes this app's controls come in.
///
/// Every control that draws itself — everything not on a system style — goes through this,
/// so a press means the same thing in the composer, in the sidebar, and on a message.
/// Controls on `.glass`, `.glassProminent`, `.bordered` and `.borderedProminent` are
/// deliberately left alone: those styles animate their own press, and replacing one to add
/// a scale would take the glass off the control to do it.
///
/// # Why this is a `PrimitiveButtonStyle`
///
/// Because a `ButtonStyle` is handed the label and the press state and **not** the action, so
/// it can draw a press but cannot decide when the press has been seen. That is one half of
/// the treatment. The other half is the owner's fourth report: *"the action currently fires
/// too quickly — there needs to be enough time for the scale-down and highlight to be clearly
/// visible before the action executes."* A `PrimitiveButtonStyle` is given
/// ``PrimitiveButtonStyleConfiguration/trigger()``, which is exactly the missing handle.
///
/// The press itself is still SwiftUI's own: the body wraps the label in an ordinary `Button`
/// carrying a `ButtonStyle` that reports `isPressed` and nothing else. That indirection is
/// load-bearing. Reading touch-down with a gesture — `DragGesture(minimumDistance: 0)`,
/// `onLongPressGesture(onPressingChanged:)`, `@GestureState` — makes a gesture start tracking
/// at touch-down, and a gesture that tracks has claimed the touch away from the scroll view
/// it is inside. This app shipped that once and the conversation could not be scrolled at all.
struct PressFeedbackButtonStyle: PrimitiveButtonStyle {
    /// How much of the treatment a control takes.
    enum Emphasis {
        /// Something with edges of its own: a button, a chip, a shortcut card, an avatar.
        /// Shrinks, and washes inside its own shape.
        case control
        /// A full-width row in a list. Shrinks, and washes inset from both screen edges in
        /// the sidebar mark's own shape.
        case row
        /// A control drawn straight onto content, with no shape of its own: the sender's
        /// name and face on a message. Shrinks and dims; draws nothing. Anything that put a
        /// shape here would turn part of a message into a button, which §3 rules out.
        case inline
    }

    var emphasis: Emphasis = .control
    /// The shape the wash is drawn in. A capsule chip and a rounded card want their own
    /// outline: a wash in the wrong shape is more visible than no wash at all.
    var shape: AnyShape

    /// The treatment in a named emphasis, washing in whatever shape that emphasis implies.
    init(_ emphasis: Emphasis = .control) {
        self.emphasis = emphasis
        self.shape = Self.defaultShape(for: emphasis)
    }

    /// The treatment in a named emphasis, washing in a shape the control names for itself —
    /// a capsule for a chip, a circle for a disc, its own radius for a card.
    init(_ emphasis: Emphasis, in shape: some Shape) {
        self.emphasis = emphasis
        self.shape = AnyShape(shape)
    }

    /// Every emphasis washes in the sidebar mark's own rounded rectangle.
    ///
    /// A row used to wash square, on the reasoning that a rounded shape against the screen's
    /// edges reads as a card. The owner settled it the other way and gave the reason: the
    /// mark on the conversation you were last in is a rounded rectangle inset from both
    /// edges, and a press that lit a row differently would be a second highlight in a list
    /// that already has one.
    private static func defaultShape(for _: Emphasis) -> AnyShape {
        AnyShape(.rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous))
    }

    func makeBody(configuration: Configuration) -> some View {
        PressFeedbackBody(configuration: configuration, emphasis: emphasis, shape: shape)
    }
}

/// The body of ``PressFeedbackButtonStyle``, as a `View` so it can hold state.
///
/// A style cannot: `makeBody` is called to produce a view, and `@State` on the style itself
/// belongs to no view. The state it needs is the timing — when the press went on, whether the
/// release it is now handling is a *lift* or an *abandonment*, and how much of the minimum is
/// left to run before the action may fire.
private struct PressFeedbackBody: View {
    let configuration: PrimitiveButtonStyleConfiguration
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        // Outside the button, so the scale takes the whole interactive view — its padding,
        // its hit area and its wash — and not just the glyphs of its label.
        .opacity(isShowing ? PressFeedback.dim(for: emphasis) : 1)
        .background {
            shape
                .fill(PressFeedback.fillColor.opacity(isShowing ? PressFeedback.fill(for: emphasis) : 0))
                .padding(.horizontal, emphasis == .row ? PressFeedback.rowInset.horizontal : 0)
                .padding(.vertical, emphasis == .row ? PressFeedback.rowInset.vertical : 0)
        }
        .scaleEffect(isShowing ? PressFeedback.scale(for: emphasis, reduceMotion: reduceMotion) : 1)
        .animation(curve, value: isShowing)
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
    /// The distinction is the owner's first report: a highlight that survives the finger
    /// leaving is a highlight that trails a scrolling list. A press interrupted by a scroll,
    /// by a drag off the control, or by the sidebar's forward swipe is not a release and must
    /// not be paid the minimum — it never became the press it was starting to be.
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

/// A control that answers a finger with nothing at all.
///
/// For the two targets on a sidebar section heading. They expand and collapse the section, and
/// the owner's second report is that they should not light up: the heading is a label with a
/// hit area, the rows below it are the list, and a heading washing in the same amber as the
/// conversation you were last in says *this one* about something that is not a conversation.
/// A style rather than `.plain`, which fades its label on press and so is not "nothing".
struct NoPressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.contentShape(.rect)
    }
}

extension PrimitiveButtonStyle where Self == PressFeedbackButtonStyle {
    /// The app's press treatment for a control with edges of its own.
    static var hivePress: PressFeedbackButtonStyle { PressFeedbackButtonStyle(.control) }

    /// The app's press treatment in a named emphasis, washing in that emphasis' own shape.
    static func hivePress(_ emphasis: PressFeedbackButtonStyle.Emphasis) -> PressFeedbackButtonStyle {
        PressFeedbackButtonStyle(emphasis)
    }

    /// The app's press treatment in a named emphasis, washing in a shape the control names
    /// for itself.
    static func hivePress(
        _ emphasis: PressFeedbackButtonStyle.Emphasis,
        in shape: some Shape
    ) -> PressFeedbackButtonStyle {
        PressFeedbackButtonStyle(emphasis, in: shape)
    }
}

extension ButtonStyle where Self == NoPressFeedbackButtonStyle {
    /// A hit area and no answer to it. See ``NoPressFeedbackButtonStyle``.
    static var hiveNoPress: NoPressFeedbackButtonStyle { NoPressFeedbackButtonStyle() }
}
