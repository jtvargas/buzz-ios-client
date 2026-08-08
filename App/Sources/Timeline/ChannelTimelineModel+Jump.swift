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
    /// # Why a watchdog rather than a deadline the walk checks
    ///
    /// Because the walk cannot check anything while a page is in flight, and a page is an
    /// HTTP request. `WindowClient.fetch` posts through `URLSession`, whose default request
    /// timeout is sixty seconds — so a relay that accepts the connection and then says nothing
    /// parks the walk inside one `await` for a minute, and a deadline tested at the top of the
    /// loop does not get a turn until long after it has passed. That is the stuck spinner:
    /// not a walk that refuses to stop, a walk that is never asked.
    ///
    /// ``startFocus(_:)`` supervises from outside instead. It settles the surface itself when
    /// the limit is reached, so what the reader sees is bounded by the limit and not by
    /// whatever the network eventually does.
    ///
    /// Cancellation belongs to whoever cancelled: the reader pressing Cancel, the watchdog, or
    /// the screen going away all want to say something different, so this says nothing at all
    /// on the way out.
    func focus(on messageID: String, sentAt: Int64) async -> FocusOutcome {
        if land(on: messageID) { return .landed }
        jump.setSeek(.searching)
        let target = TimelineCursor(createdAt: sentAt, id: messageID)
        var stalls = 0

        for _ in 0 ..< Self.focusPageBudget {
            if Task.isCancelled { return .gaveUp }
            // Before the load rather than after it, so a message already behind the loaded
            // floor when the walk starts costs no page at all.
            if hasWalkedPast(target) { return settleMissing(messageID) }
            guard hasMoreOlder else { return settleMissing(messageID) }

            let before = loaded.count
            await loadOlder()
            if Task.isCancelled { return .gaveUp }
            // Takes the panel down as well as landing: the reader is looking at the message,
            // which is the whole answer, and a surface still saying it is looking for it is
            // the loudest possible way to be wrong.
            if land(on: messageID) { return settleLanded() }

            guard loaded.count == before else {
                stalls = 0
                continue
            }
            // A pass that brought nothing back is not the end of history — see
            // ``ChannelTimelineModel/focusStallBudget`` for the three ordinary ways
            // ``loadOlder()`` arrives here. Wait for whatever it was, then ask again.
            stalls += 1
            if stalls >= Self.focusStallBudget { return report(.unreachable) }
            try? await Task.sleep(for: Self.focusStallPause)
        }
        return report(.unreachable)
    }

    // MARK: - Owning the reach

    /// Starts the reach for a message, under a watchdog, and remembers it so it can be run
    /// again.
    ///
    /// Fire-and-forget on purpose: the caller is a `.task` that must not be left awaiting a
    /// walk the reader may cancel and restart several times. What the walk *finds* comes back
    /// through ``focusThreadRoot`` instead, which is a fact about this screen rather than a
    /// return value belonging to one particular attempt.
    func startFocus(_ focus: ConversationFocus) {
        focusRequest = focus
        focusTask?.cancel()
        focusTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let walk = Task { @MainActor [weak self] in
                await self?.focus(on: focus.messageID, sentAt: focus.sentAt) ?? .gaveUp
            }
            let watchdog = Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.focusDeadline)
                guard !Task.isCancelled, let self else { return }
                // The order matters. Reporting *before* the cancel means the surface is
                // settled by the time the walk notices, so nothing the walk does on its way
                // out can be mistaken for the answer — and if the request it is inside never
                // honours the cancel at all, the reader is still told.
                jump.setSeek(.failed(.unreachable))
                walk.cancel()
            }
            let outcome = await walk.value
            watchdog.cancel()
            if case let .inThread(root) = outcome { focusThreadRoot = root }
        }
    }

    /// Runs the reach again from where the screen now stands.
    ///
    /// Not from scratch: the pages the last attempt did load are ordinary loaded history, so a
    /// second attempt starts nearer the message than the first. That is what makes retrying a
    /// timeout worth offering rather than a way to wait the same fifteen seconds twice.
    func retryFocus() {
        guard let focusRequest else { return }
        startFocus(focusRequest)
    }

    /// Stops the reach at the reader's word, and takes the report off with it.
    ///
    /// Also how the surface is dismissed after a failure — there is nothing left running by
    /// then, and "stop telling me" is the same instruction.
    func cancelFocus() {
        focusTask?.cancel()
        focusTask = nil
        jump.setSeek(.none)
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

    /// The reader is on the message. Nothing left to report.
    private func settleLanded() -> FocusOutcome {
        jump.setSeek(.none)
        return .landed
    }

    /// Whether the loaded floor has gone past where the message would be.
    ///
    /// Strictly past: a floor *equal* to the target is the target, which ``land(on:)`` has
    /// already been asked about.
    private func hasWalkedPast(_ target: TimelineCursor) -> Bool {
        guard let earliest else { return false }
        return (earliest.createdAt, earliest.id) < (target.createdAt, target.id)
    }

    /// The floor has gone past this message's place — so ask what that actually proved.
    ///
    /// Three answers, and telling them apart is the difference between a true sentence and a
    /// confident one.
    ///
    /// **It is in the log and names a thread.** A reply the channel page excludes by
    /// construction — see the `NOT EXISTS` against `thread` in `fetchTimeline` — so its thread
    /// is a surface to send the reader to rather than a failure to report.
    ///
    /// **It is in the log and names no thread.** Then it is genuinely not on this surface:
    /// every row at or after its place is loaded, the message is in the log, and it is not
    /// among them. `Message not found` is a claim about this conversation, and here it is
    /// true.
    ///
    /// **It is not in the log at all.** Then nothing has been proved. The walk's own proof is
    /// that the loaded rows are contiguous *with what this device holds* — and a device that
    /// never stored the message may equally never have stored the stretch around it, so its
    /// order has a hole the walk cannot see. This is exactly the relay-only result the row
    /// marks `Fetches on open`, and answering it `Message not found` states as a fact about
    /// the conversation something that is only a fact about the local store. It is
    /// ``ConversationSeekFailure/unreachable``: we could not get there.
    private func settleMissing(_ messageID: String) -> FocusOutcome {
        guard let row = storedRow(messageID) else { return report(.unreachable) }
        guard let root = row.rootID else { return report(.notFound) }
        jump.setSeek(.none)
        return .inThread(root: root)
    }

    /// The message as this device holds it, if it holds it.
    ///
    /// A read failure answers `nil`, which routes to ``ConversationSeekFailure/unreachable`` —
    /// the honest verdict for a question that could not be asked.
    private func storedRow(_ messageID: String) -> TimelineRow? {
        try? store.rows(for: [messageID], selfPubkey: selfPubkey).first
    }

    /// Shows one of the two endings, and leaves it up.
    ///
    /// It used to clear itself after three seconds. That was wrong in the way a reader
    /// notices: the one state worth acting on is the one that took itself away while they were
    /// still reading it, and a failure with a **Try again** on it has to survive long enough to
    /// be pressed. ``cancelFocus()`` is how it goes.
    private func report(_ reason: ConversationSeekFailure) -> FocusOutcome {
        jump.setSeek(.failed(reason))
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
