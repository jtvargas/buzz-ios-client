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

    /// Releases the frozen tail, rebuilds the rendered rows, and lands on a loaded message.
    ///
    /// This is the Stage 1 boundary: no store or relay lookup is attempted. A target that is
    /// not rendered yet remains armed until the first loaded snapshot gives the view an honest
    /// answer. ``ChannelTimelineView`` supplies that readiness through ``hasLoaded``.
    @discardableResult
    func prepareLanding(on eventID: String) -> Bool {
        pendingLanding = eventID
        tail.release()
        rebuild()
        guard pendingLanding == nil else {
            if hasLoaded { pendingLanding = nil }
            return false
        }
        return true
    }

    /// Re-asks for a pending message-link landing once its row is in the rendered set.
    ///
    /// Called from ChannelTimelineModel.rebuild(). Like landOnOwnSend(among:), this touches
    /// only the jump command, never isAtBottom: writing that flag here would re-enter rebuild
    /// through its own observer. A frozen row remains pending until the landing request
    /// releases the tail and rebuilds.
    func landOnPending(among rendered: [TimelineRow]) {
        guard let target = pendingLanding,
              rendered.contains(where: { $0.id == target }) else { return }
        pendingLanding = nil
        jumpTarget = .message(target)
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
        jumpTarget = .message(target)
        jumpToken += 1
    }
}
