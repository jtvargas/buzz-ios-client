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
    /// is the common case; a tenth of a second also covers a control whose action lands a
    /// frame or two late, and is far short of the interval between two deliberate taps.
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
