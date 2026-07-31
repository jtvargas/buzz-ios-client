import SwiftUI

/// The numbers behind every control's answer to a finger.
///
/// They live here rather than as literals in each style because the whole point of the
/// treatment is that it is *one* treatment: a chip that answers one way beside a card that
/// answers another reads as two apps. The same reasoning as ``MessageRowMetrics`` — values
/// agreeing in eleven files is an accident waiting to be changed in one of them.
///
/// # Nothing here moves
///
/// **There is no scale.** A press was drawn as a shrink for five rounds, at 0.965, then 0.94,
/// then 0.97, and the owner's verdict on the last of them was *"forget about it, I don't want
/// that scale animation"*. It is not dialled to 1 — it is gone, so that adding one back is a
/// deliberate act with this paragraph in front of it. What is left is light: a **control**
/// washes the accent inside its own shape, a **row** dims a few per cent, an **inline**
/// control dims further, and a **message** answers nothing at all, because the long press it
/// is on its way to announces itself with a haptic and then a sheet.
///
/// # The shape of the gesture
///
/// Three curves, all ease-outs, differing only in how long they take. Down is fast, because a
/// press has to answer immediately. Up is slower, because a release is allowed to settle. And
/// a press that is **abandoned** — the finger moved, the scroll view took the touch — comes off
/// in a fraction of either, with no latch in front of it: a highlight that trails a scrolling
/// finger is the most common way this treatment reads as broken, and it is not a release, so
/// it must not animate like one.
///
/// # None of it stands in front of the action
///
/// The action fires the moment the finger leaves, and the release plays *over* whatever the
/// action started — a push, a sheet, a send. For one round it did not: the action waited for
/// the press to have been seen, which is a defensible way to make a press perceptible and
/// an indefensible way to make an app feel, and the owner reported the whole app as laggy
/// within the hour. Feedback is drawn *beside* what it is feedback for, never in front of it.
enum PressFeedback {
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

    /// How long a press stays on screen at the very least.
    ///
    /// `isPressed` follows the finger exactly, and a quick tap is shorter than the curve that
    /// draws it — so without this the wash starts to arrive, the finger lifts, and it fades
    /// back out from somewhere around a tenth of its opacity. The latch lets the down-curve
    /// land before the release begins, and it is set to ``pressDuration`` for exactly that
    /// reason: it is the shortest hold that can show the whole animation and not a millisecond
    /// of dwell beyond it.
    ///
    /// It holds the *drawing* and nothing else. It briefly held the action too — see this
    /// type's own documentation — and that is the one thing it must never be made to do again.
    /// A press interrupted by a new one drops it: a control tapped twice in a row answers the
    /// second tap immediately rather than finishing its account of the first.
    static let minimumVisible: TimeInterval = pressDuration

    /// What a pressed control's content fades to.
    ///
    /// Two depths, and with the scale gone this is now the **whole** answer a row gives. The
    /// owner has removed, in order: the amber wash from rows, and then the shrink from
    /// everything. What is left on a list row is a few per cent of light coming out of its
    /// content — deliberately quiet, and flagged to him as the one dial still available if it
    /// reads as nothing at all. The **inline** controls on a message, the sender's face and
    /// name, take the deep one, because they draw no shape and have nothing else either.
    static let pressedDim: Double = 0.92
    static let inlinePressedDim: Double = 0.55

    /// The corner radius the wash is drawn with when a control does not name its own shape.
    /// The sidebar mark's, and `.continuous` like it.
    static let cornerRadius: CGFloat = 10

    /// How long the press takes to land, how long the release takes to settle, and how long
    /// an abandoned press takes to disappear.
    ///
    /// 90ms down, which is the owner's 80–100ms and is about five frames: fast enough to read
    /// as *the moment I touched it*, slow enough to be an animation rather than a jump.
    static let pressDuration: TimeInterval = 0.09
    static let releaseDuration: TimeInterval = 0.22
    /// Near enough to instant to be gone within two frames of the finger moving.
    static let cancelDuration: TimeInterval = 0.06

    /// Down: fast where the finger is.
    static let press = Animation.easeOut(duration: pressDuration)

    /// Up: the same curve, given longer to settle.
    ///
    /// It was a spring while there was a scale to spring — an overshoot is what makes movement
    /// read as physical, and it is meaningless on an opacity, which cannot usefully go past
    /// its target. With the scale gone the honest curve is the plain one.
    static let release = Animation.easeOut(duration: releaseDuration)

    /// Abandoned: off the screen before the finger has travelled a centimetre.
    static let cancel = Animation.easeOut(duration: cancelDuration)

    /// The animation for a transition *into* `isPressed`.
    ///
    /// Reduce Motion is not consulted, and that is not an oversight: nothing in this treatment
    /// moves any more. A cross-fade is what the setting *prefers* to movement, not something
    /// it declines.
    static func animation(pressed: Bool) -> Animation {
        pressed ? press : release
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
/// deliberately left alone: those styles answer a press themselves, and replacing one to add
/// this would take the glass off the control to do it.
///
/// # Why this is a `PrimitiveButtonStyle`
///
/// Not to delay anything — it did that for one round and the owner reported the app as laggy.
/// It stays primitive for the one fact only ``PrimitiveButtonStyleConfiguration/trigger()``
/// can tell it: **whether this press ended in an activation or in a cancel.**
/// `configuration.isPressed` goes false identically either way, so a plain `ButtonStyle`
/// cannot tell a lift from a scroll view taking the touch away — and those two have to animate
/// differently, or every flick down a list leaves a highlight trailing the finger. `trigger()`
/// is called on touch-up-inside and never on a cancel, so it is the signal, and it is passed
/// straight through the moment it arrives.
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
        /// Washes the accent inside its own shape.
        case control
        /// A full-width row in a list. Dims very slightly and draws no wash — the owner had
        /// the amber taken off the sidebar entirely, and then the shrink off everything, so
        /// this is all a row has left.
        case row
        /// A control drawn straight onto content, with no shape of its own: the sender's
        /// name and face on a message. Dims, and draws nothing. Anything that put a shape
        /// here would turn part of a message into a button, which §3 rules out.
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
/// measures the pixels — which is what now holds the *absence* of a scale to something firmer
/// than a promise: a pressed row's ink must land in exactly the box the resting one did.
///
/// There is no `scaleEffect` here and there must not be one. See ``PressFeedback``.
struct PressTreatment: ViewModifier {
    let isShowing: Bool
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? PressFeedback.dim(for: emphasis) : 1)
            .background {
                shape.fill(
                    PressFeedback.fillColor
                        .opacity(isShowing ? PressFeedback.fill(for: emphasis) : 0)
                )
            }
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
