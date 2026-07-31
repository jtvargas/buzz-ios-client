import SwiftUI

/// The numbers behind every control's answer to a finger.
///
/// They live here rather than as literals in each style because the whole point of the
/// treatment is that it is *one* treatment: a chip that shrinks to 0.96 beside a card that
/// shrinks to 0.92 reads as two apps. The same reasoning as ``MessageRowMetrics`` — values
/// agreeing in eleven files is an accident waiting to be changed in one of them.
///
/// # What answers a finger, and what does not
///
/// A **control** shrinks and washes inside its own shape. A **row** only shrinks: the owner
/// had the amber wash taken off the sidebar entirely, and off a message entirely, so on a
/// list the movement is the whole answer. A **message** now answers nothing at all — the row
/// under a finger is content, the long press it is on its way to announces itself with a
/// haptic and then a sheet, and the wash that used to say *this one* was a third thing
/// nobody asked for.
///
/// # The shape of the gesture
///
/// Three curves. Down is a fast ease-out, because a press has to answer immediately. Up is a
/// spring, because the release is the moment a control is allowed to feel physical. And a
/// press that is **abandoned** — the finger moved, the scroll view took the touch — comes off
/// in a sixth of the time either of those take, with no latch in front of it: a highlight
/// that trails a scrolling finger is the most common way this treatment reads as broken, and
/// it is not a release, so it must not animate like one.
enum PressFeedback {
    /// What a pressed control shrinks to.
    ///
    /// Six per cent, which is past the brief's original 0.96–0.97 on the owner's instruction
    /// — he reported the shrink as invisible three times running, the last time with the
    /// amber taken off, which leaves the movement carrying the whole answer by itself. On the
    /// widest thing this is applied to, a full-width sidebar row on a 390pt screen, it moves
    /// each edge about 12pt; on the narrowest, a composer disc, about 1pt. Below 0.94 the
    /// label re-lays out at the accessibility text sizes, which is the floor this sits on.
    ///
    /// The number is only half of that report, and it was the smaller half. The other half is
    /// ``ScrollTouchDeliveryView``: a scroll view holds a touch for about 150ms before the
    /// control inside it is told there was one, so on the shortest taps the shrink was
    /// starting after the finger had already left. A deeper scale cannot be seen through a
    /// delay in front of it.
    static let pressedScale: CGFloat = 0.94

    /// The wash a pressed **control** draws behind itself, inside its own shape.
    ///
    /// The accent at 0.14, which is not a taste call — it is
    /// ``ChannelListView/resumeMark(isResumable:)``, the mark on the conversation you were
    /// last in, to the number. It is drawn only where a control has edges of its own now: on
    /// a list row and on a message the owner had it removed, and the reason is worth keeping
    /// — the amber is the app's *place* mark, and a list that flashes it under every finger
    /// is a list saying *this one* about whatever you happened to touch.
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
    static let minimumVisible: TimeInterval = 0.22

    /// What a pressed control's content fades to.
    ///
    /// Two depths. A **row** takes the shallow one: with the wash gone the movement is alone,
    /// and a few per cent of light coming out of the content is the one reinforcement
    /// available that is not a coloured highlight — which is the thing that was removed. The
    /// **inline** controls on a message, the sender's face and name, take the deep one,
    /// because they draw no shape and have nothing else at all.
    static let pressedDim: Double = 0.92
    static let inlinePressedDim: Double = 0.55

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
    /// "unnecessary movement" the setting exists to decline.
    static func animation(pressed: Bool, reduceMotion: Bool) -> Animation {
        guard !reduceMotion else { return press }
        return pressed ? press : release
    }

    /// What a pressed control of this emphasis shrinks to. Only Reduce Motion declines it —
    /// with the wash gone from rows and messages, movement is most of what is left.
    static func scale(for _: PressFeedbackButtonStyle.Emphasis, reduceMotion: Bool) -> CGFloat {
        reduceMotion ? 1 : pressedScale
    }

    /// What a pressed control of this emphasis fades to.
    static func dim(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        switch emphasis {
        case .control: 1
        case .row: pressedDim
        case .inline: inlinePressedDim
        }
    }

    /// The wash a pressed control of this emphasis draws in its own shape. Only a control
    /// with edges of its own draws one — see ``pressedFill``.
    static func fill(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        emphasis == .control ? pressedFill : 0
    }
}

/// Slack's press treatment, in the three shapes this app's controls come in.
///
/// Every control that draws itself — everything not on a system style — goes through this,
/// so a press means the same thing in the composer, in the sidebar, and in a sheet.
/// Controls on `.glass`, `.glassProminent`, `.bordered` and `.borderedProminent` are
/// deliberately left alone: those styles animate their own press, and replacing one to add
/// a scale would take the glass off the control to do it.
///
/// # Why this is a `PrimitiveButtonStyle`
///
/// Because a `ButtonStyle` is handed the label and the press state and **not** the action, so
/// it can draw a press but cannot decide when the press has been seen. That is one half of
/// the treatment. The other half is the owner's report that *"the action fires too quickly —
/// there needs to be enough time for the scale-down to be clearly visible before the action
/// executes."* A `PrimitiveButtonStyle` is given
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
        /// A full-width row in a list. Shrinks and dims very slightly; draws no wash — the
        /// owner had the amber taken off the sidebar entirely.
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
        self.shape = Self.defaultShape
    }

    /// The treatment in a named emphasis, washing in a shape the control names for itself —
    /// a capsule for a chip, a circle for a disc, its own radius for a card.
    init(_ emphasis: Emphasis, in shape: some Shape) {
        self.emphasis = emphasis
        self.shape = AnyShape(shape)
    }

    /// The sidebar mark's own rounded rectangle, for a control that names no shape.
    private static let defaultShape = AnyShape(
        .rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous)
    )

    func makeBody(configuration: Configuration) -> some View {
        PressFeedbackBody(configuration: configuration, emphasis: emphasis, shape: shape)
    }
}

/// What a press *looks* like, as a modifier over a plain `Bool`.
///
/// Split out of the style on purpose, and it is the only part of this file a test can hold to
/// the screen. `ImageRenderer` can render a view; it cannot press a button. So the treatment
/// is a function of `isShowing` alone, `PressFeedbackTests` renders it at both values and
/// measures where the ink landed, and "the scale-down is not happening" — reported three
/// times — stops being a claim anyone has to take on trust.
struct PressTreatment: ViewModifier {
    let isShowing: Bool
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? PressFeedback.dim(for: emphasis) : 1)
            .background {
                shape.fill(
                    PressFeedback.fillColor
                        .opacity(isShowing ? PressFeedback.fill(for: emphasis) : 0)
                )
            }
            .scaleEffect(isShowing ? PressFeedback.scale(for: emphasis, reduceMotion: reduceMotion) : 1)
    }
}

extension View {
    /// Draws this view as pressed, or not. See ``PressTreatment``.
    func pressTreatment(
        isShowing: Bool,
        emphasis: PressFeedbackButtonStyle.Emphasis = .control,
        in shape: AnyShape = AnyShape(.rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous))
    ) -> some View {
        modifier(PressTreatment(isShowing: isShowing, emphasis: emphasis, shape: shape))
    }
}

/// A control that answers a finger with nothing at all.
///
/// For the two targets on a sidebar section heading. They expand and collapse the section, and
/// the owner's instruction is that they should not light up: the heading is a label with a hit
/// area, and the rows below it are the list. A style rather than `.plain`, which fades its
/// label on press and so is not "nothing".
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
