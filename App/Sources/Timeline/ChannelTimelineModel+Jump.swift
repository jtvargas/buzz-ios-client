import BuzzKit
import Foundation

// MARK: - Jumps

/// Where the affordance above the composer takes the reader, kept beside the model
/// rather than in it so the model file stays about the observation, pagination, and the
/// freeze itself.
extension ChannelTimelineModel {
    /// Releases the frozen tail, renders everything loaded, and asks the view to
    /// scroll to the newest row.
    ///
    /// No control offers this any more — `↓ Latest` is gone. It stays because an own send
    /// still needs it (``shouldJumpToOwnSend``), and because it is where
    /// ``jumpToNewMessages()`` lands a press that raced the reader back to the bottom.
    ///
    /// The freeze is exactly the inverse of ``isAtBottom``, so setting that releases
    /// it — asserted, not waited for. The scaffold's geometry callback confirms the
    /// position a frame later and re-freezes if the scroll did not land.
    func jumpToLatest() {
        isAtBottom = true
        jumpTarget = .bottom
        jumpToken += 1
    }

    /// Re-asks for the jump an own send already started, now that the message is on screen.
    ///
    /// Called from ``rebuild()``, which is why only ``jumpTarget`` and ``jumpToken`` are
    /// touched: writing ``isAtBottom`` here would call `rebuild` again from its own `didSet`.
    /// There is nothing left for it to do anyway — the send released the freeze at the tap,
    /// which is the only reason this row is among `rendered` to be found.
    func landOnOwnSend(among rendered: [TimelineRow]) {
        guard let awaiting = awaitingOwnSend,
              rendered.contains(where: { $0.id == awaiting }) else { return }
        awaitingOwnSend = nil
        jumpTarget = .bottom
        jumpToken += 1
    }

    /// Lands the author on the message they just sent, now that it has an id.
    ///
    /// The second half of the trip ``send()`` started at the tap. If the row is already
    /// rendered — the store's observation beat the enqueue's return — the jump goes now;
    /// otherwise it is recorded and ``landOnOwnSend(among:)`` fires it the moment the row lands.
    ///
    /// # Why there is no "is the author still at the bottom" guard here
    ///
    /// Because ``isAtBottom`` cannot answer that question at this moment. The jump the tap
    /// asked for is *animating*, and the scaffold writes this flag from scroll geometry on the
    /// way — a reader who was parked in history is still 800 points from the bottom on the
    /// first frame, so `isAtBottom` goes back to `false` mid-flight and returns to `true` when
    /// the animation lands. Measured: guarding on it here left the second jump unasked and the
    /// author's own message 67 points under the composer.
    ///
    /// The freeze is the guard instead, and it is the honest one. An author who really has
    /// gone back to reading history re-arms it, their own message is held behind it like any
    /// other arrival, and a row that is not rendered is never landed on.
    func landOn(ownSend eventID: String) {
        guard rows.contains(where: { $0.id == eventID }) else {
            awaitingOwnSend = eventID
            return
        }
        jumpTarget = .bottom
        jumpToken += 1
    }

    /// Renders the held-back arrivals and lands the reader on the *first* of them.
    ///
    /// Not ``jumpToLatest()``: the pill's whole claim is "three things happened", and
    /// dropping someone at the bottom puts all three above the fold — read to the end by
    /// being scrolled past. The first unread row is where reading resumes.
    ///
    /// ``isAtBottom`` stays `false`, which is the honest report of where this leaves
    /// them — so ``rebuild()`` re-arms the boundary at what is now the newest row, and
    /// anything arriving while they read what they just asked for is held and counted
    /// afresh rather than moving them again. Landing at the bottom anyway (few enough new
    /// rows that the scroll runs out of content) is what the scaffold's geometry reports a
    /// frame later, which releases the freeze in the ordinary way.
    ///
    /// Nothing held back means the press raced the reader back to the bottom: the bottom
    /// is then the honest destination, and a control that moves nothing when pressed is
    /// worse than one that goes somewhere.
    func jumpToNewMessages() {
        guard let target = jump.firstUnreadID else { return jumpToLatest() }
        tail.release()
        rebuild()
        jumpTarget = .message(target, animated: true)
        jumpToken += 1
    }

    // MARK: - Arriving from somewhere else

    /// Takes the reader to one particular message, paging history back until it is there.
    ///
    /// The arrival case: search today, and whatever else later asks to open a conversation
    /// *at* something. The conversation opens where it always does — at its newest message —
    /// and this walks backwards behind it until the row exists to be scrolled to.
    ///
    /// # Why it pages rather than seeding a window around the message
    ///
    /// A window would be one read instead of a walk, and it would leave a hole: the rows
    /// between that window and the newest page were never loaded, and nothing in this model
    /// represents a hole. A reader scrolling down out of the window would pass from one
    /// island straight into the other with a stretch of the conversation silently missing
    /// and nothing to tell them. Paging is slower and honest — the loaded set stays what it
    /// claims to be, which every other rule in this file already leans on.
    ///
    /// # Why this must not be called before the first layout
    ///
    /// It ends in a ``ChannelTimelineModel/jumpToken`` bump, and a bump made before
    /// ``ConversationScaffold`` has installed its `onChange` is a change that observer never
    /// sees — the same reason ``ThreadModel/landOnOpener()`` is driven from a `.task` rather
    /// than from a prime.
    ///
    /// Cancellation is the caller's `.task`: leaving the screen ends the walk where it
    /// stands, and what it did load is ordinary loaded history.
    func focus(on messageID: String) async {
        if land(on: messageID) { return }
        jump.setSeek(.searching)
        for _ in 0 ..< Self.focusPageBudget {
            guard hasMoreOlder, !olderFailed, !Task.isCancelled else { break }
            let before = loaded.count
            await loadOlder()
            if land(on: messageID) { return jump.setSeek(.none) }
            // A pass that brought nothing back cannot be repeated into a different answer.
            // ``loadOlder()`` already walks its own budget of relay pages while the reader is
            // given nothing to see, so arriving here with the count unchanged means the pager
            // ran out or failed — both of which it does report, but only on the pass after.
            if loaded.count == before { break }
        }
        guard !Task.isCancelled else { return jump.setSeek(.none) }
        // Say so. A reach that quietly gives up cannot be told apart from one still running,
        // and the reader is left at the newest message wondering why their tap did nothing.
        // It clears itself rather than offering a retry: a second reach walks the same
        // ground to the same end.
        jump.setSeek(.failed)
        try? await Task.sleep(for: .seconds(3))
        jump.setSeek(.none)
    }

    /// Scrolls to a loaded message and marks it; answers `false` when it is not loaded.
    ///
    /// The distance is counted in *rows*, which is the one count on this surface that is not
    /// an estimate — see ``ConversationJumpTarget/message(_:animated:)`` for why the scaffold
    /// does not work it out from geometry instead.
    @discardableResult
    func land(on messageID: String) -> Bool {
        // The rendered rows, not the loaded ones: a row behind the frozen tail has no frame
        // for the scroll view to find, so the scroll would move nothing and report nothing.
        guard let index = rows.firstIndex(where: { $0.id == messageID }) else { return false }
        let rowsFromNewest = rows.count - 1 - index
        jumpTarget = .message(messageID, animated: rowsFromNewest <= Self.animatedLandingRows)
        jumpToken += 1
        highlight(messageID)
        return true
    }

    /// Marks a row as the one the reader came for, and takes the mark away again.
    ///
    /// Long enough to be seen after a scroll that takes a fifth of a second, short enough
    /// that it is gone before it starts reading as a selection.
    func highlight(_ messageID: String) {
        highlightTask?.cancel()
        highlightedMessageID = messageID
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            self?.highlightedMessageID = nil
        }
    }
}
