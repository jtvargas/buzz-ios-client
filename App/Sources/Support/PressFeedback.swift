import SwiftUI

/// The numbers behind every control's answer to a finger.
///
/// They live here rather than as literals in each `ButtonStyle` because the whole point of
/// the treatment is that it is *one* treatment: a chip that shrinks to 0.96 beside a card
/// that shrinks to 0.92 reads as two apps. The same reasoning as ``MessageRowMetrics`` —
/// values agreeing in eleven files is an accident waiting to be changed in one of them.
///
/// # The shape of the gesture
///
/// Down is an ease-out and up is a spring, deliberately, and not one curve used both ways.
/// A press has to answer *immediately* — an ease-out is fastest where the finger is, at the
/// start — while the release is the moment the control is allowed to feel physical, and a
/// spring's small overshoot is what reads as springy rather than as a fade. Both are inside
/// the fifth of a second a control has before the feedback stops feeling like a consequence
/// of the touch.
enum PressFeedback {
    /// What a pressed control shrinks to.
    ///
    /// The shallow end of the range a touch can register at all: at 0.95 and below the label
    /// visibly re-lays out at the accessibility text sizes, and a wide row appears to jump
    /// away from the screen edges.
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

    /// How long a press stays on screen at the very least.
    ///
    /// The reason the first cut of this "didn't animate": `isPressed` follows the finger
    /// exactly, and a tap is often shorter than the 0.16s the shrink takes to arrive. The
    /// scale would start, reach about 0.99, and spring back — a flicker, not a press. Slack's
    /// deliberate feel is this: once a press is shown it plays through, however fast the tap
    /// was. Past the ease-out, and short enough that a double tap still reads as two.
    static let minimumVisible: TimeInterval = 0.18

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

    /// How long the press takes to land, and how long the release takes to settle.
    ///
    /// Named rather than written into the two animations below because they are the one
    /// part of this file that came from the brief as a number — "≈0.15–0.2s, snappy" — and a
    /// constant is the only form of that a test can hold the app to.
    static let pressDuration: TimeInterval = 0.16
    static let releaseDuration: TimeInterval = 0.2

    /// Down: fast where the finger is.
    static let press = Animation.easeOut(duration: pressDuration)

    /// Up: snappy, with the small overshoot that reads as physical.
    static let release = Animation.spring(response: releaseDuration, dampingFraction: 0.7)

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
    /// A free function rather than a computed property inside the style so the vocabulary
    /// can be asserted: "a row does not shrink" and "Reduce Motion shrinks nothing" are the
    /// two rules most likely to be undone by a later hand, and neither is visible in a
    /// screenshot of a resting screen.
    static func scale(for emphasis: PressFeedbackButtonStyle.Emphasis, reduceMotion: Bool) -> CGFloat {
        guard !reduceMotion, emphasis != .row else { return 1 }
        return pressedScale
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
struct PressFeedbackButtonStyle: ButtonStyle {
    /// How much of the treatment a control takes.
    enum Emphasis {
        /// Something with edges of its own: a button, a chip, a shortcut card, an avatar.
        /// Shrinks, and washes inside its own shape.
        case control
        /// A full-width row in a list. Washes, and does **not** shrink — a row that pulls
        /// away from both screen edges reads as a card lifting off the list, which is the
        /// one thing a row is not.
        case row
        /// A control drawn straight onto content, with no shape of its own: the sender's
        /// name and face on a message. Shrinks and dims; draws nothing. Anything that put a
        /// shape here would turn part of a message into a button, which §3 rules out.
        case inline
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
    /// that already has one. It is inset rather than full-bleed for exactly the reason the
    /// square was chosen — see ``PressFeedback/rowInset``.
    private static func defaultShape(for _: Emphasis) -> AnyShape {
        AnyShape(.rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous))
    }

    func makeBody(configuration: Configuration) -> some View {
        PressFeedbackBody(configuration: configuration, emphasis: emphasis, shape: shape)
    }
}

/// The body of ``PressFeedbackButtonStyle``, as a `View` so it can hold state.
///
/// A `ButtonStyle` cannot: `makeBody` is called to produce a view, and `@State` on the style
/// itself belongs to no view. The state it needs is the latch — the thing that makes a press
/// visible on a tap too fast to see, which is the whole difference between this and the first
/// cut that the owner reported as "the shrink animation doesn't happen".
private struct PressFeedbackBody: View {
    let configuration: PressFeedbackButtonStyle.Configuration
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Whether the press is being *shown*, which is not the same as whether a finger is down.
    @State private var isShowing = false
    @State private var shownAt: Date?
    @State private var release: Task<Void, Never>?

    var body: some View {
        configuration.label
            // Every adopter gets a hit area covering its whole frame; a `Text` otherwise
            // only accepts taps on its glyphs.
            .contentShape(.rect)
            .opacity(isShowing ? PressFeedback.dim(for: emphasis) : 1)
            .background {
                shape
                    .fill(PressFeedback.fillColor.opacity(isShowing ? PressFeedback.fill(for: emphasis) : 0))
                    .padding(.horizontal, emphasis == .row ? PressFeedback.rowInset.horizontal : 0)
                    .padding(.vertical, emphasis == .row ? PressFeedback.rowInset.vertical : 0)
            }
            .scaleEffect(isShowing ? PressFeedback.scale(for: emphasis, reduceMotion: reduceMotion) : 1)
            // Scoped to this control's own press, never ambient: an animation reaching the
            // enclosing list would animate row insertion in a bottom-anchored scroll view.
            .animation(PressFeedback.animation(pressed: isShowing, reduceMotion: reduceMotion), value: isShowing)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { show() } else { hide() }
            }
            .onDisappear { release?.cancel() }
    }

    private func show() {
        release?.cancel()
        release = nil
        shownAt = .now
        isShowing = true
    }

    /// Takes the press off, but never before it has been on screen long enough to be seen.
    private func hide() {
        let shownFor = shownAt.map { Date.now.timeIntervalSince($0) } ?? PressFeedback.minimumVisible
        let remaining = PressFeedback.minimumVisible - shownFor
        guard remaining > 0 else {
            isShowing = false
            return
        }
        release = Task { @MainActor in
            try? await Task.sleep(for: .seconds(remaining))
            guard !Task.isCancelled else { return }
            isShowing = false
        }
    }
}

extension ButtonStyle where Self == PressFeedbackButtonStyle {
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
