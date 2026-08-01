import CoreGraphics

/// What ``ConversationReaderPlace`` does about the *room below the conversation* changing —
/// the keyboard taking it, and the composer's own bar taking it.
///
/// Kept beside the type rather than in it because these are a different kind of input from
/// the rest of that file. Everything there is handed an estimated number and has to infer
/// what caused it; everything here is a change whose cause is **declared**, so it needs no
/// settling window and reads no extent at all. The two share one rule and nothing else.
extension ConversationReaderPlace {
    /// The keyboard came up or went away, taking room off the bottom of the scrollable
    /// region or giving it back. Says what that implies for the reader's place.
    ///
    /// # Why this is a separate entrance and not another geometry reading
    ///
    /// Because this is the one height change in this surface whose *cause* is known, and the
    /// rest of this type exists precisely because the causes are not. ``correction(for:)``
    /// is handed a number and has to infer whether content arrived or the `LazyVStack`
    /// re-measured; it gets that right by refusing to act unless the owner declared a
    /// commit. A keyboard declares itself: the room above it changed, nothing was inserted,
    /// and no estimate is involved.
    ///
    /// # Why an at-bottom reader is moved and a reader in history is not
    ///
    /// For a reader resting on the newest message, the keyboard arriving is the message they
    /// are about to reply to going under it — the owner's report, verbatim: *"the message list
    /// does not push up, the composer and keyboard end up covering the latest message"*. For a
    /// reader parked in history it is nothing: what they are reading is nowhere near the bottom
    /// edge, and moving the conversation under them to make room at an end they are not looking
    /// at is the same defect this file spends the rest of its length preventing — and the
    /// owner's own scope, *"if the user has scrolled up at all, no push is required"*.
    ///
    /// So the predicate is the one already written above for a content change: a
    /// conversation nobody has moved belongs at its newest message, and so does one whose
    /// reader is already there. Everyone else stays where they are.
    ///
    /// # How often this does anything, and why it is not `.sizeChanges` again
    ///
    /// Less often than it looks. A scroll view already resting against its bottom has its
    /// offset clamped up when an inset takes room there, so most conversations follow with no
    /// help at all. It earns its place on the ones whose content landed *after* the first
    /// layout, where the resting offset is not against the true bottom — nothing clamps, and
    /// the newest message does not move by a single point. Measured on iPhone 17 Pro / iOS 26
    /// against a 311-point keyboard, unmodified `main`, `ConversationScrollTests`:
    /// `thread-8-longlast` moved 311 and `thread-8-longlast-primed` — the same content
    /// delivered one relay round trip later — moved **0**, leaving 299 points of the message
    /// under the keyboard. `thread-12-longlast` moved 0 in that run and 311 in the one before
    /// it, which is why the report was "a weird issue": it turns on how much of the stack had
    /// been measured when the keyboard arrived.
    ///
    /// `defaultScrollAnchor(.bottom, for: .sizeChanges)` is the modifier that used to cover
    /// this, and it is deliberately gone — see ``ConversationScaffold``. The difference is not
    /// the trigger, which is the same container change; it is the destination. That anchor
    /// resolved against `contentSize.height`, and on a `LazyVStack` measuring one row taller
    /// than the viewport that number is largely invented, so it landed the reader past the end
    /// of the real content with nothing rendered. This lands on a row.
    ///
    /// # What this deliberately does not cover
    ///
    /// A composer that grows *under typing* takes room off the same edge for the same reason,
    /// and is still not wired to anything: doing so from the bar's own geometry is what turned
    /// the growth suite into a runner the harness killed as unresponsive, twice, and that
    /// diagnosis is open. An attachment is covered — by ``composerRoomDidChange(isAtBottom:)``,
    /// which is declared rather than measured and so cannot reach a keystroke. See
    /// ``ConversationScaffold`` for both.
    ///
    /// - Parameter isAtBottom: whether the scaffold's own hysteresis currently reads the
    ///   reader as resting on the newest message.
    func keyboardRoomDidChange(isAtBottom: Bool) -> Correction {
        roomBelowDidChange(isAtBottom: isAtBottom)
    }

    /// The composer itself changed height — a picture was attached, or the strip holding one
    /// went away.
    ///
    /// The same room, off the same edge, with the same decision behind it, so it is the same
    /// rule; what differs is where the trigger comes from. A keyboard is a container change
    /// this surface can see. The bar's height is a number this surface *measures*, and
    /// measuring it is what hung the runner — so the owner declares the change instead, from
    /// the one event that causes it. See ``ConversationScaffold/composerRevision``.
    ///
    /// Kept as its own entrance rather than folded into the keyboard's, because the two are
    /// only the same by coincidence of the current rule: if an attachment ever wants a
    /// different destination from a keyboard — the strip rather than the newest row, say —
    /// this is where that difference goes, and a shared name would have hidden the question.
    func composerRoomDidChange(isAtBottom: Bool) -> Correction {
        roomBelowDidChange(isAtBottom: isAtBottom)
    }

    /// The rule both entrances share: a conversation nobody has moved belongs at its newest
    /// message, and so does one whose reader is already there. Everyone else stays put.
    private func roomBelowDidChange(isAtBottom: Bool) -> Correction {
        // A finger on the list outranks the keyboard: a correction mid-drag fights the
        // reader, exactly as it does on a content change. This is also the interactive
        // dismissal, where the room above the keyboard changes on every frame of a drag.
        guard !isScrolling else { return .none }
        guard !hasMoved || isAtBottom else { return .none }
        return .bottom
    }
}
