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
    /// # How it knows when to stop
    ///
    /// By `sentAt`, and only by it. The rows are held in the `(created_at, id)` total order
    /// the page query itself pages by, so once the oldest loaded row is *older* than the
    /// message's own key, every row at or after where the message would be is loaded — and it
    /// is not among them. That is a proof, it costs one comparison, and it is what lets "not
    /// here" be an answer rather than a guess made when something else ran out first.
    ///
    /// Everything else that ends the walk — the relay refusing, the page budget, the stall
    /// budget — proves nothing about the message, and is reported as
    /// ``ConversationSeekFailure/unreachable`` rather than as "not found".
    ///
    /// Cancellation is the caller's `.task`: leaving the screen ends the walk where it
    /// stands, and what it did load is ordinary loaded history.
    func focus(on messageID: String, sentAt: Int64) async -> FocusOutcome {
        if land(on: messageID) { return .landed }
        jump.setSeek(.searching)
        let target = TimelineCursor(createdAt: sentAt, id: messageID)
        var stalls = 0

        for _ in 0 ..< Self.focusPageBudget {
            if Task.isCancelled { return settleCancelled() }
            // Before the load rather than after it, so a message already behind the loaded
            // floor when the walk starts costs no page at all.
            if hasWalkedPast(target) { return await settleMissing(messageID) }
            guard hasMoreOlder else { return await settleMissing(messageID) }

            let before = loaded.count
            await loadOlder()
            if land(on: messageID) { return .landed }

            guard loaded.count == before else {
                stalls = 0
                continue
            }
            // A pass that brought nothing back is not the end of history — see
            // ``ChannelTimelineModel/focusStallBudget`` for the three ordinary ways
            // ``loadOlder()`` arrives here. Wait for whatever it was, then ask again.
            stalls += 1
            if stalls >= Self.focusStallBudget { return await report(.unreachable) }
            try? await Task.sleep(for: Self.focusStallPause)
        }
        return await report(.unreachable)
    }

    /// How ``focus(on:sentAt:)`` ended, for a caller that can do something about it.
    enum FocusOutcome: Equatable {
        /// The reader is looking at the message.
        case landed
        /// It is not on this surface, but the walk pulled it in on the way past and it names
        /// a thread — so it is one of the replies this channel's page excludes by
        /// construction, and its thread is where the reader was trying to go.
        ///
        /// This is the case a *relay* search result falls into. The index this device holds
        /// answers with a thread root; the relay's search answers with event ids and nothing
        /// else, so a reply that had never reached this device could only be sent to its
        /// channel and left to fail there. It becomes knowable by the end of the walk,
        /// because the walk is what stored it.
        case inThread(root: String)
        /// The walk ended without the message and there is nothing further to try. Already
        /// reported on the surface; the caller has nothing to do.
        case gaveUp
    }

    /// Whether the loaded floor has gone past where the message would be.
    ///
    /// Strictly past: a floor *equal* to the target is the target, which ``land(on:)`` has
    /// already been asked about.
    private func hasWalkedPast(_ target: TimelineCursor) -> Bool {
        guard let earliest else { return false }
        return (earliest.createdAt, earliest.id) < (target.createdAt, target.id)
    }

    /// The reader left. Saying anything about it would be saying it to whoever opens this
    /// conversation next.
    private func settleCancelled() -> FocusOutcome {
        jump.setSeek(.none)
        return .gaveUp
    }

    /// Proved absent from this conversation — so ask the one question that is left.
    ///
    /// The walk has been past this message's place, which means anything the store now holds
    /// under that id was stored *by the walk*. A row here that names a thread is a reply the
    /// channel page excludes — see the `NOT EXISTS` against `thread` in `fetchTimeline` — and
    /// that is a surface to send the reader to rather than a failure to report.
    private func settleMissing(_ messageID: String) async -> FocusOutcome {
        if let root = threadRoot(of: messageID) {
            jump.setSeek(.none)
            return .inThread(root: root)
        }
        return await report(.notFound)
    }

    /// The thread a message belongs to, if this device holds the message and it names one.
    ///
    /// A read failure answers `nil`: the caller's next move is then to report that the
    /// message was not found, which is what it would have reported anyway.
    private func threadRoot(of messageID: String) -> String? {
        guard let row = try? store.rows(for: [messageID], selfPubkey: selfPubkey).first else {
            return nil
        }
        return row.rootID
    }

    /// Shows one of the two endings, and takes it away again.
    ///
    /// Says something rather than going quiet: a reach that gives up silently cannot be told
    /// apart from one still running, and the reader is left at the newest message wondering
    /// why their tap did nothing. Neither ending offers a retry — one is a proof a second
    /// press cannot overturn, and the other has already re-tried inside the walk.
    private func report(_ reason: ConversationSeekFailure) async -> FocusOutcome {
        jump.setSeek(.failed(reason))
        try? await Task.sleep(for: .seconds(3))
        jump.setSeek(.none)
        return .gaveUp
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
