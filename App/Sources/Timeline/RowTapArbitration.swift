import Foundation

/// Whether a tap that has already landed on one of a message row's own controls should
/// also be allowed to open the row's thread.
///
/// Beside ``TimelineRowView`` rather than inside it, the same way ``TimelineRowChrome``'s
/// views are: that file is about the row's own hierarchy, and this is a rule with no view
/// in it.
///
/// A deadline rather than a flag with a timer behind it. Both express "for a moment after a
/// control acts", but a flag needs a second scheduled block to clear it, and two controls
/// acting inside the same window then leave one block clearing a suppression the other had
/// just set. A deadline has nothing to keep in step — and it makes the rule a value, so the
/// ordering it exists to enforce is unit-tested instead of eyeballed on a device.
struct RowTapArbitration {
    /// How long a control's action keeps the row's own tap from firing.
    ///
    /// One main-actor turn would be enough for the gestures that complete together, which
    /// is the common case; the rest of this covers a control whose action lands a frame or two
    /// late, and is still far short of the interval between two deliberate taps.
    ///
    /// It is deliberately *not* derived from ``PressFeedback/minimumVisible``, which it was
    /// for one round. That derivation went with a row tap deferred by the same minimum, so
    /// that a pressed message's wash could be seen before the thread replaced it; with the
    /// wash gone the row opens its thread on the next main-actor turn, and a window scaled to
    /// a press-visibility constant would only mean a real tap on a message being swallowed
    /// because a chip beside it was brushed a fifth of a second earlier.
    ///
    /// What has to reach inside this window is the *claim*, and it does: a control carrying
    /// the app's press treatment calls ``ClaimRowTapAction`` as the finger leaves it, one turn
    /// before the row's tap asks.
    static let window: TimeInterval = 0.1

    private var suppressedUntil: Date?

    /// Records that a control on the row has just handled this tap.
    mutating func controlDidAct(now: Date = .now) {
        suppressedUntil = now.addingTimeInterval(Self.window)
    }

    /// Whether the row's deferred tap should be dropped.
    func suppressesRowTap(now: Date = .now) -> Bool {
        guard let suppressedUntil else { return false }
        return suppressedUntil > now
    }
}
