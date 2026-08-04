import SwiftUI

/// The numbers behind every control's answer to a finger.
///
/// They live here rather than as literals in each style because the whole point of the
/// treatment is that it is *one* treatment: a chip that answers one way beside a card that
/// answers another reads as two apps. The same reasoning as ``MessageRowMetrics`` — values
/// agreeing in eleven files is an accident waiting to be changed in one of them.
///
/// # The scale is back, and this paragraph is the receipt
///
/// A press was drawn as a shrink for five rounds — 0.965, then 0.94, then 0.97 — and the
/// owner's verdict on the last of them was *"forget about it, I don't want that scale
/// animation"*. It was removed outright rather than dialled to 1, precisely so that putting
/// one back would be a deliberate act with this paragraph in front of it. **On 2026-08-04 he
/// asked for it back**, in a spec naming 0.975, a fast spring in and a softer one out.
///
/// It is worth being exact about what was wrong before, because none of it was the scale:
///
/// - it **arrived ~150ms late**, behind `UIScrollView.delaysContentTouches`, so on a short tap
///   it arrived after the finger had gone. That is ``ScrollTouchDeliveryView``'s job now, and
///   it was fixed after the scale had already been removed for being invisible;
/// - for one round the **action waited behind it**, and the owner reported the whole app as
///   laggy within the hour. ``PressFeedbackBody/fire()`` has nothing in front of it now;
/// - and it was drawn with an **ease-out**, which cannot reverse from a moving state, so a
///   quick tap either played the whole shrink or looked like a stutter. A spring can, which is
///   the difference this round rests on.
///
/// So the shrink is on a control and on a row, and it is **not** on an `.inline` control —
/// the sender's name and face on a message. Scaling a run of text inside a paragraph moves the
/// paragraph, and a message answers nothing anyway.
///
/// Light is the rest of the answer, and it moved the same way the next day: he asked for
/// *"some highlight container with the same accent color but very dim — 0.00 → 0.08 → 0.00"*,
/// so a **control** and a **row** both wash the accent inside their own shape at
/// ``pressedFill``, a **row** dims a few per cent as well, an **inline** control only dims and
/// dims further, and a **message** answers nothing at all.
///
/// # The shape of the gesture
///
/// **Springs, since there is something to spring again.** Down is fast, because a press has to
/// answer immediately. Up is given longer to settle, and both are damped flat — an overshoot on
/// a 2.5% shrink reads as a wobble, not as physics. A press that is **abandoned** — the finger
/// moved, the scroll view took the touch — comes off in a fraction of either, with no latch in
/// front of it: a highlight that trails a scrolling finger is the most common way this
/// treatment reads as broken, and it is not a release, so it must not animate like one.
///
/// SwiftUI's springs are **retargetable**: changing the destination mid-flight continues from
/// the current value *and the current velocity* rather than restarting. That is the whole of
/// the owner's "quick taps reverse smoothly before the scale-down finishes", and it is why
/// ``minimumVisible`` no longer stands in front of the release — see that property.
///
/// # None of it stands in front of the action
///
/// The action fires the moment the finger leaves, and the release plays *over* whatever the
/// action started — a push, a sheet, a send. For one round it did not: the action waited for
/// the press to have been seen, which is a defensible way to make a press perceptible and
/// an indefensible way to make an app feel, and the owner reported the whole app as laggy
/// within the hour. Feedback is drawn *beside* what it is feedback for, never in front of it.
enum PressFeedback {
    /// The wash a pressed control draws behind itself, inside its own shape.
    ///
    /// **The owner's number, given as `0.00 → 0.08 → 0.00` on 2026-08-04**, and the arrow is
    /// the whole specification: a highlight that is not there at rest, reaches 0.08 under the
    /// finger, and is not there again after. That is what an opacity on `isShowing` already
    /// draws, riding ``press`` and ``release`` — no second animation was added for it.
    ///
    /// It was 0.14, and that number was not a taste call either: it was
    /// ``ChannelListView/resumeMark(isResumable:)``, the mark on the conversation you were last
    /// in, to the number. **Being exactly that mark is why it had to come off a row.** The
    /// amber is the app's *place* mark, and a list that flashes the place mark under every
    /// finger is a list saying *this one* about whatever you happened to touch.
    ///
    /// 0.08 is a little over half of it, which is what lets the wash go back on a row: it is
    /// now visibly a *press* rather than a claim about where you were. The two are still the
    /// same hue on purpose — one accent, said at two strengths — so this constant and
    /// `resumeMark`'s 0.14 must stay apart. If a later hand equalises them, the row wash has to
    /// come off again.
    static let pressedFill: Double = 0.08

    /// The colour of that wash. Named here so the sidebar's mark and every press in the app
    /// cannot drift apart without this line changing.
    /// Computed, not stored: a `static let` captures the accent at first touch and would keep
    /// drawing the theme that was in force then.
    static var fillColor: Color { .hiveAccent }

    /// How long a press stays on screen at the very least — **zero, now that a spring draws it.**
    ///
    /// It was ``pressDuration``, and the reasoning was sound for the treatment it was written
    /// for: `isPressed` follows the finger exactly, a quick tap is shorter than an ease-out, so
    /// without a latch the wash started to arrive, the finger lifted, and it faded back from
    /// about a tenth of its opacity. The latch let the down-curve land first.
    ///
    /// A spring does not need that, and with one it is actively the wrong shape. A spring
    /// reverses **from wherever it currently is, carrying its velocity**, so a quick tap gives
    /// a small real dip rather than a stutter — no latch required. Keeping the latch would hold
    /// the control compressed for 90ms after the finger had already gone, which is the owner's
    /// *"quick taps reverse smoothly before the scale-down finishes"* read backwards, and his
    /// *"no artificial delay"* broken outright.
    ///
    /// **This is the one behaviour that changes for reasons other than the scale**, so it is
    /// the one dial to turn first if a quick tap now reads as too faint. Set it back to
    /// ``pressDuration`` and the old latch returns.
    ///
    /// It has only ever held the *drawing*. It briefly held the action too — see this type's
    /// own documentation — and that is the one thing it must never be made to do again.
    static let minimumVisible: TimeInterval = 0

    /// What a pressed control's content fades to.
    ///
    /// Two depths. A row now answers with three things at once — the shrink, this dim, and the
    /// wash — where a round ago it had only this one. That is deliberate rather than
    /// accumulated: the owner asked for the shrink and the highlight back in consecutive
    /// messages, and 0.08 of accent is faint enough that dropping the dim to compensate would
    /// leave a row answering more quietly than it did before either was asked for. **It is the
    /// first thing to take off if a pressed row now reads as too loud** — set it to 1 and the
    /// row keeps the shrink and the wash, which is exactly what a ``control`` does.
    ///
    /// The **inline** controls on a message, the sender's face and name, take the deep one,
    /// because they draw no shape and so have nothing else at all.
    static let pressedDim: Double = 0.92
    static let inlinePressedDim: Double = 0.55

    /// The corner radius the wash is drawn with when a control does not name its own shape.
    /// The sidebar mark's, and `.continuous` like it.
    static let cornerRadius: CGFloat = 10

    /// What a pressed control shrinks to.
    ///
    /// The owner's number, given as 0.975 after he had previously rejected 0.94 and 0.97. On a
    /// 240pt row that is six points across the whole width and three at the leading edge —
    /// deliberately near the floor of what reads as movement at all, because the thing being
    /// asked for is *that it answered*, not a squeeze.
    static let pressedScale: CGFloat = 0.975

    /// Which emphases move. A control and a row do; an `.inline` control does not.
    ///
    /// The sender's name and face on a message draw straight onto the message's own text, with
    /// no shape of their own. Scaling a run inside a paragraph reflows the paragraph around it,
    /// so the sentence under the finger moves — which is a different and much louder event than
    /// a control answering. See this type's own documentation.
    static func scale(for emphasis: PressFeedbackButtonStyle.Emphasis) -> CGFloat {
        emphasis == .inline ? 1 : pressedScale
    }

    /// How long the press takes to land, how long the release takes to settle, and how long
    /// an abandoned press takes to disappear.
    ///
    /// 90ms down, which is the owner's 80–140ms and is about five frames: fast enough to read
    /// as *the moment I touched it*, slow enough to be an animation rather than a jump. 220ms
    /// up, in the middle of his 180–260ms.
    static let pressDuration: TimeInterval = 0.09
    static let releaseDuration: TimeInterval = 0.22
    /// Near enough to instant to be gone within two frames of the finger moving.
    static let cancelDuration: TimeInterval = 0.06

    /// Down: fast where the finger is.
    ///
    /// A spring rather than an ease-out, and `bounce: 0` rather than a default spring. The
    /// reason for the spring is **not** the overshoot — it is that a spring is retargetable, so
    /// a finger that lifts 30ms into a 90ms press reverses from where the control actually is,
    /// carrying its velocity, instead of snapping to a new curve. The reason for the flat bounce
    /// is that an overshoot on a 2.5% shrink is a wobble, and the owner asked for no bounce and
    /// no overshoot in the same breath as he asked for the spring.
    static let press = Animation.spring(duration: pressDuration, bounce: 0)

    /// Up: the same spring, given longer to settle, and allowed the faintest amount of life.
    ///
    /// `bounce: 0.12` is under a tenth of a point of overshoot at this scale — not enough to
    /// see as a bounce, enough to keep the settle from reading as mechanical. It is the one
    /// number here that is taste rather than arithmetic, and the first one to take to zero if
    /// the release reads as loose.
    static let release = Animation.spring(duration: releaseDuration, bounce: 0.12)

    /// Abandoned: off the screen before the finger has travelled a centimetre.
    static let cancel = Animation.spring(duration: cancelDuration, bounce: 0)

    /// The animation for a transition *into* `isPressed`.
    static func animation(pressed: Bool) -> Animation {
        pressed ? press : release
    }

    /// The same, for a reader who has asked the system for less movement.
    ///
    /// Reduce Motion does not mean "no feedback" — it means *prefer a cross-fade to a
    /// movement*. So the shrink is dropped (``scale(for:)`` is overridden to 1 at the call
    /// site) and the wash and the dim stay, on the plain ease-outs this treatment used before
    /// the scale came back. A spring with nothing left to spring is just a slower fade.
    static func animation(pressed: Bool, reduceMotion: Bool) -> Animation {
        guard reduceMotion else { return animation(pressed: pressed) }
        return pressed
            ? .easeOut(duration: pressDuration)
            : .easeOut(duration: releaseDuration)
    }

    /// What a pressed control of this emphasis fades to.
    static func dim(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        switch emphasis {
        case .control: 1
        case .row: pressedDim
        case .inline: inlinePressedDim
        }
    }

    /// The wash a pressed control of this emphasis draws in its own shape. See ``pressedFill``.
    ///
    /// A control and a row both draw one now. An `.inline` control still draws none, and that
    /// is the one exclusion here that is not about strength: the sender's name and face sit
    /// directly on a message's own text with no shape of their own, so a wash behind them would
    /// put a lit rectangle around a run of a sentence — which is turning part of a message into
    /// a button, and is ruled out for the same reason ``scale(for:)`` exempts them.
    static func fill(for emphasis: PressFeedbackButtonStyle.Emphasis) -> Double {
        emphasis == .inline ? 0 : pressedFill
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
        /// A full-width row in a list. Washes the accent like a control, and dims very
        /// slightly on top of it. Both of those were off for a while — the owner had the amber
        /// taken off the sidebar when it was drawn at the resume mark's own 0.14, and then the
        /// shrink off everything — and both came back at his ask, the wash at a strength that
        /// can no longer be mistaken for the mark. See ``PressFeedback/pressedFill``.
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
/// measures the pixels — which is what holds the shrink to a number rather than to a promise.
///
/// # The `scaleEffect` and where it is anchored
///
/// `.center`, which is the default and is named here anyway because it is the only anchor that
/// does not make a row appear to slide. A row is much wider than it is tall, so a shrink
/// anchored at a leading edge moves its trailing edge by the whole 2.5% while the leading edge
/// stays put — which reads as the row being tugged sideways rather than pressed. Centred, both
/// edges come in by half of it and the movement reads as depth.
///
/// It sits **outside** the wash rather than inside it: the wash is the control's own surface,
/// so it must shrink with the control. Applying the scale first and the background after would
/// leave a full-size wash around a shrunken label.
struct PressTreatment: ViewModifier {
    let isShowing: Bool
    let emphasis: PressFeedbackButtonStyle.Emphasis
    let shape: AnyShape
    /// Whether the reader has asked the system for less movement. The shrink is the only part
    /// of this treatment that moves, so this drops it and leaves the light alone.
    var reduceMotion: Bool = false

    private var scale: CGFloat {
        guard isShowing, !reduceMotion else { return 1 }
        return PressFeedback.scale(for: emphasis)
    }

    func body(content: Content) -> some View {
        content
            .opacity(isShowing ? PressFeedback.dim(for: emphasis) : 1)
            .background {
                shape.fill(
                    PressFeedback.fillColor
                        .opacity(isShowing ? PressFeedback.fill(for: emphasis) : 0)
                )
            }
            .scaleEffect(scale, anchor: .center)
    }
}

extension View {
    /// Draws this view as pressed, or not. See ``PressTreatment``.
    func pressTreatment(
        isShowing: Bool,
        emphasis: PressFeedbackButtonStyle.Emphasis = .control,
        in shape: AnyShape = AnyShape(.rect(cornerRadius: PressFeedback.cornerRadius, style: .continuous)),
        reduceMotion: Bool = false
    ) -> some View {
        modifier(
            PressTreatment(isShowing: isShowing, emphasis: emphasis, shape: shape, reduceMotion: reduceMotion)
        )
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
