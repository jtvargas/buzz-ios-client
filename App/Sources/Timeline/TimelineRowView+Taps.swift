import SwiftUI

/// Which of the things a message row can do a given finger meant.
///
/// Split out of `TimelineRowView.swift` for the reason `TimelineRowView+Identity.swift` is —
/// that file is about the row's own hierarchy — and because this is where the row's hardest
/// rules live: three separate arbitrations run over one touch, and every one of them has been
/// the cause of a tap silently doing nothing at some point in this surface's life.
///
/// - ``RowTapArbitration`` decides whether the row's own tap should run at all, or whether a
///   control inside it already answered the same touch.
/// - ``MessageTapArbiter`` decides whether a tap was single or the first half of a double.
/// - `pressGesture` decides between a tap and a long press, and is the one place on this row
///   that may observe the press *at all*.
extension TimelineRowView {
    // MARK: - Tap arbitration

    /// How long a press has to be held before it is the actions sheet rather than a tap.
    /// Shorter than `LongPressGesture`'s own half-second default, which reads as a hesitation
    /// on a message; long enough that the flick that starts a scroll is not one.
    static let longPressDuration: TimeInterval = 0.35

    /// A tap and a long press over the same row, resolved by the system rather than by the
    /// arbitration below.
    ///
    /// `exclusively(before:)` and not two separately attached gestures, and that is the whole
    /// reason this is a computed gesture instead of an `onTapGesture` beside an
    /// `onLongPressGesture`: SwiftUI's `TapGesture` has **no maximum duration**. A press held
    /// for a second and then lifted satisfies it, so with both attached the sheet would open
    /// on recognition and the thread would be pushed behind it on release. Exclusive
    /// composition gives the long press first refusal and only evaluates the tap when the
    /// press ended too early to be recognised.
    ///
    /// The `guard` is not a nicety: without a sheet to open, an armed long press would win
    /// the press and swallow the tap, which is the Threads screen's rows losing their only
    /// way into a thread.
    ///
    /// This gesture deliberately reports **nothing** about the press going down, and nothing
    /// in this file may be added that does.
    ///
    /// It did once, through `@GestureState` hung off the long press, and that shipped a
    /// conversation that could not be scrolled at all: a gesture that tracks from touch-down
    /// has taken the touch, and a 45% drag beginning on a message then moves the list 0.0pt.
    /// The replacement — a UIKit recogniser that never left `.possible` — worked, and is gone
    /// too, because the owner then had the highlight it fed removed from the message
    /// altogether. There is now nothing on this row that observes a touch going down, which
    /// is the safest state this surface has been in. `ConversationDragScrollTests` is what
    /// holds the line if that changes.
    var pressGesture: AnyGesture<Void> {
        let tap = TapGesture().onEnded { scheduleRowTap() }
        guard let onLongPress, !row.isDeleted else { return AnyGesture(tap) }
        return AnyGesture(
            LongPressGesture(minimumDuration: Self.longPressDuration)
                .onEnded { _ in
                    // What the context menu this replaced played on recognition, and what
                    // tells a reader the sheet is coming before it has drawn a pixel.
                    HiveHaptics.play(.longPress)
                    onLongPress()
                }
                .exclusively(before: tap)
                .map { _ in () }
        )
    }

    /// Hands the tap to ``messageTapped(_:)`` on the next main-actor turn, and never before a
    /// control the same tap also landed on has claimed it.
    ///
    /// One turn, and no longer — *this* delay is only the arbitration below. It was briefly
    /// ``PressFeedback/minimumVisible``, so that a pressed message's wash had somewhere to be
    /// seen before the thread replaced the screen it was drawn on — and then the owner had
    /// that wash removed. A delay in front of a navigation with nothing drawn during it is not
    /// a considered pause, it is lag: the row would answer the finger with nothing at all for a
    /// fifth of a second and then jump.
    ///
    /// The thread then waits again, for ``MessageTapArbiter/doubleTapWindow``, and that
    /// second wait is not the same kind of thing: it buys a gesture the app did not have, it is
    /// the reader's own second tap it is waiting for, and it is skipped entirely on a surface
    /// with no sheet to open.
    ///
    /// The turn is still needed, because the tap and the control actions that beat it are
    /// dispatched from the same event in no guaranteed order. One turn is all it needs, and
    /// the claim comes from a control's *action*: nothing on this row delays an action any
    /// more, so every claim lands in the same event the tap did. It was briefly claimed from
    /// the *press* instead, while actions were being held back behind the press animation —
    /// and a cancelled press claims identically to a completed one, so brushing a chip and
    /// scrolling away suppressed the next real tap on the row.
    ///
    /// The controls that claim a tap, and how each one does it:
    ///
    /// - the avatar and the sender's name, the reaction chips, and the reply preview are
    ///   `Button`s whose actions run through ``performControlAction(_:)``;
    /// - a link inside the message body claims it in the `OpenURLAction` below, which is
    ///   the only hook a tappable run of `AttributedString` offers;
    /// - the failed-send strip's Retry claims it the same way the chips do — its closure
    ///   used to be passed straight through, so retrying a send that is not in the store
    ///   also pushed a thread for it;
    /// - the add-reaction pill is a `Menu`, which has *no* about-to-open hook at all, so
    ///   ``AddReactionButton`` carries a `simultaneousGesture` tap instead. That composes
    ///   with the menu's own recogniser rather than replacing it, so the palette still
    ///   opens; and it is effective exactly where the problem is, because the tap it
    ///   observes is the same touch-up the row's own tap gesture completes on.
    ///
    /// Anything added to the row that is a control has to join that list. There is no
    /// mechanism here that notices one by itself.
    func scheduleRowTap() {
        // Either outcome is enough to be worth deferring for: a thread to open, or a sheet a
        // second tap could ask for. Inside a thread there is no thread to open and the double
        // tap is the only thing this gesture still does.
        guard !row.isDeleted, onOpenThread != nil || onLongPress != nil else { return }
        DispatchQueue.main.async {
            guard !arbitration.suppressesRowTap() else { return }
            messageTapped { onOpenThread?() }
        }
    }

    /// Resolves one tap on this message — wherever on it the finger landed — into `single` or
    /// into the actions sheet, by waiting to see whether a second tap follows.
    ///
    /// Reached from two places, and it matters that it is only two: the row's own tap gesture
    /// above, and a picture inside the message, which hands over what it would have done
    /// through ``MessageTapAction`` rather than doing it. **One physical tap must arrive here
    /// once.** A picture that opened itself *and* let the row count the same touch would read
    /// as a double tap from a single finger — which is why the claim above is checked first:
    /// a tap a control has claimed has already been counted by whoever claimed it, and the
    /// row's own gesture drops it.
    ///
    /// The one gesture this cannot resolve is a tap immediately followed by a *held* press —
    /// the second half of a double tap that the finger stayed down for. The single tap runs at
    /// the end of its window, half way through the hold, and the long press is cancelled along
    /// with the screen it was on. Reading it correctly would mean observing the touch going
    /// down, which is the one thing this row may never do (see ``pressGesture``).
    func messageTapped(_ single: @escaping () -> Void) {
        taps.tapped(single: single, double: actionsSheetTap)
    }

    /// The actions sheet, as the answer to a second tap: the same outcome as the long press,
    /// announced the same way — a haptic before the sheet has drawn a pixel.
    ///
    /// `nil` where there is no sheet — the Threads screen's summaries, and a deleted message —
    /// and that absence is load-bearing: it is what keeps a tap on those surfaces immediate
    /// rather than deferred behind a gesture they do not offer.
    var actionsSheetTap: (() -> Void)? {
        guard let onLongPress, !row.isDeleted else { return nil }
        return {
            HiveHaptics.play(.longPress)
            onLongPress()
        }
    }

    /// Internal for the same reason ``avatarSize`` is: the avatar and the name are
    /// controls, and they live in the identity file.
    func performControlAction(_ action: () -> Void) {
        claimTap()
        action()
    }

    /// Claims the current tap without running anything, for a control whose action is not
    /// this row's to run — the add-reaction pill, where the thing being opened is a menu
    /// and the emoji it eventually reports is a separate event.
    func claimTap() {
        arbitration.controlDidAct()
    }}
