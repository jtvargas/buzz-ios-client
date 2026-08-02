import BuzzKit

/// How many replies the thread has, for the rule under its opener.
extension ThreadModel {
    /// The count ``ThreadOpenerDivider`` writes, as the thread's own opener advertises it.
    ///
    /// Read off the opener row rather than counted from ``rows``, and the difference is not
    /// cosmetic: `rows` is the *rendered* set, and it is short of the thread in two ordinary
    /// situations.
    ///
    /// - A reader parked away from the bottom has the tail frozen (see ``TimelineTail``), so
    ///   arriving replies are deliberately held back. Counting rendered rows would make the
    ///   number *fall* as the thread grew.
    /// - A thread opened cold holds nothing until the one-shot fetch returns, so the count
    ///   would start at zero and jump — on the first frame, which is the one
    ///   ``primeIfNeeded()`` exists to get right.
    ///
    /// The opener's own ``BuzzKit/TimelineRow/replyCount`` is neither: it is the tally that
    /// message carried in the channel the reader tapped it from, composed by `TimelineQuery`
    /// from this device's replies and the relay's summary of the thread. Reading it here is
    /// what makes the number on this screen the number the channel already showed, rather
    /// than a second count of the same thing arrived at a different way.
    ///
    /// Zero while the opener is not on screen yet — drawn the same way as a thread nobody
    /// has answered, which is to say not at all. See ``ThreadOpenerDivider/replyLabel(for:)``.
    var replyCount: Int {
        rows.first { $0.id == root }?.replyCount ?? 0
    }
}
