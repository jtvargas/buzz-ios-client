import BuzzKit
import Foundation

/// Where a thread sends the reader, and when.
///
/// Split out of ``ThreadModel`` the way ``ChannelTimelineModel``'s jumps are split out of
/// it: the model is a store observation with rows on one side and a set of small,
/// self-contained scroll intents on the other, and the two read better apart.
///
/// Every one of these ends the same way — set ``ThreadModel/jumpTarget``, bump
/// ``ThreadModel/jumpToken`` — because the scaffold watches the token and reads the
/// target. Setting the target without the bump is a jump that never happens, which is the
/// one mistake this file exists to keep in one place.
extension ThreadModel {
    /// Releases the frozen tail and asks the view to scroll to the newest reply.
    func jumpToLatest() {
        isAtBottom = true
        jumpTarget = .bottom
        jumpToken += 1
    }

    /// Renders the held-back replies and lands the reader on the *first* of them —
    /// where reading resumes, rather than at the bottom past everything the pill just
    /// announced. See ``ChannelTimelineModel/jumpToNewMessages()`` for why the reader is
    /// left away from the bottom, and what re-arms behind them.
    func jumpToNewMessages() {
        guard let target = jump.firstUnreadID else { return jumpToLatest() }
        tail.release()
        rebuild()
        jumpTarget = .message(target)
        jumpToken += 1
    }

    /// Lands the reader on the message that opened this thread, for a thread reached by
    /// someone asking what it is about rather than what they missed.
    ///
    /// Called from a `.task` and not from ``ThreadModel/primeIfNeeded()``, which is the
    /// whole reason this is a method rather than an initial value: `primeIfNeeded` runs at
    /// the top of the first `body`, and a `jumpToken` already bumped by the time the
    /// scaffold installs its `onChange` is a change that observer never sees. A `.task`
    /// runs after that first render, so the bump is a real transition.
    ///
    /// It reuses the ordinary `.message` jump — the same path `N new messages` takes, and
    /// the one the conversation UI suite already gates — rather than touching the scroll
    /// view's initial anchor, which is load-bearing for the blank-conversation defects of
    /// #49/#50/#52 and is not worth reopening for a landing.
    ///
    /// Does nothing when the opener is not among the loaded rows. That should not happen
    /// — the caller read it from this same store to draw the row that was tapped — and
    /// resting at the newest reply is the right fallback if it somehow does.
    func landOnOpener() {
        guard rows.contains(where: { $0.id == root }) else { return }
        jumpTarget = .message(root)
        jumpToken += 1
    }

    /// Whether an own reply has to move the thread at all. Already at the bottom with
    /// nothing held back, the author is looking straight at where it will appear, and
    /// re-anchoring interrupts a scroll in progress for no gain. Read at the tap and
    /// carried — see ``ChannelTimelineModel/shouldJumpToOwnSend``.
    var shouldJumpToOwnSend: Bool {
        !isAtBottom || jump.unreadCount > 0
    }

    /// Re-asks for the jump an own reply already started, now that it is on screen. Touches
    /// only the jump, never ``ThreadModel/isAtBottom`` — see
    /// ``ChannelTimelineModel/landOnOwnSend(among:)`` for why writing that from inside
    /// `rebuild` would call `rebuild` again.
    func landOnOwnSend(among rendered: [TimelineRow]) {
        guard let awaiting = awaitingOwnSend,
              rendered.contains(where: { $0.id == awaiting }) else { return }
        awaitingOwnSend = nil
        jumpTarget = .bottom
        jumpToken += 1
    }

    /// Lands the author on the reply they just sent, now that it has an id — the second half
    /// of the trip the tap started. See ``ChannelTimelineModel/landOn(ownSend:)``, including
    /// why the freeze is the only guard here and ``isAtBottom`` is not one.
    func landOn(ownSend eventID: String) {
        guard rows.contains(where: { $0.id == eventID }) else {
            awaitingOwnSend = eventID
            return
        }
        jumpTarget = .bottom
        jumpToken += 1
    }
}
