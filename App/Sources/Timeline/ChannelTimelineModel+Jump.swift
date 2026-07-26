import BuzzKit
import Foundation

// MARK: - Jumps

/// Where the two affordances above the composer take the reader, kept beside the model
/// rather than in it so the model file stays about the observation, pagination, and the
/// freeze itself.
extension ChannelTimelineModel {
    /// Releases the frozen tail, renders everything loaded, and asks the view to
    /// scroll to the newest row — `↓ Latest`, and an own send.
    ///
    /// The freeze is exactly the inverse of ``isAtBottom``, so setting that releases
    /// it — asserted, not waited for. The scaffold's geometry callback confirms the
    /// position a frame later and re-freezes if the scroll did not land.
    func jumpToLatest() {
        isAtBottom = true
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
