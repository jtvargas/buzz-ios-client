import CoreGraphics

/// Where the reader is in a conversation, and what should happen to that place when the
/// content changes height underneath them.
///
/// # Why this exists at all
///
/// `defaultScrollAnchor(.bottom, for: .sizeChanges)` reads as though it covers this. For a
/// *container* change it does — measured, raising the keyboard moves the offset by exactly
/// the inset it adds. For a **content** change against a `LazyVStack` it does nothing.
/// Measured on iPhone 17 Pro / iOS 26.0 in a harness built around the shipping
/// ``ConversationScaffold`` (`~/.buzz/.scratch/scrollharness`), inserting an older page of
/// 50 rows above a reader:
///
/// | | content height | content offset | rows on screen |
/// |---|---|---|---|
/// | before | 45 882 | 44 300 | 1047–1049 |
/// | after | 80 338 | **44 300** | **997–999** |
///
/// The raw offset is kept — which is `.top` behaviour — and the reader is thrown a whole
/// page backwards.
///
/// > Retracted. A paragraph here used to say that removing `.scrollPosition` and removing the
/// `.sizeChanges` anchor had each been measured, separately and together, and that all four
/// variants behaved identically — so neither modifier owned the defect and neither could be
/// traded for it. **That comparison never happened.** The variants were selected by launch
/// arguments (`-noposition`, `-nosizeanchor`) that no code in the harness ever read, so all
/// four runs were the same binary. The claim then stood for two pull requests as the reason
/// not to touch the anchor. Rebuilt as real source patches, the `.sizeChanges` anchor turned
/// out to own a defect of its own, and it is gone — see ``ConversationScaffold``. An arm is a
/// patched copy of these files now (`~/.buzz/.scratch/harness-*/Sources/`), so a variant that
/// was not built cannot compile.
///
/// # What this type still gets wrong
///
/// A settling window closes on a run of readings whose height held still, and **a conversation
/// at rest produces no readings at all** — `onScrollGeometryChange` fires on change. So a
/// window opened by a reaction chip or an arriving reply stands until the reader touches
/// something, and what they usually touch is the composer: the keyboard is then spent as that
/// old commit settling, and a reader up in history is moved. Measured, five of thirteen shapes,
/// all of them with a live store: **821–861 points for a 311-point keyboard**.
///
/// Closing the window on a container change fixes exactly that and costs more than it saves —
/// measured, it takes the keyboard's own re-pin away from a reader who is *at* the newest
/// message, and the blank conversation returns in four shapes. Narrowing it to re-pin only an
/// at-bottom reader was also measured, and lands between the two (eight failures against one).
/// Both attempts are recorded in `mem/buzz-ios-scroll-round3`; neither is in the tree.
///
/// The reason no arrangement of this file gets both cases to zero is that every input it has —
/// `contentSize.height`, `contentOffset.y`, and the distance derived from them — is estimated
/// by the `LazyVStack` it is measuring. Apple's guidance is now explicit: *"avoid using the
/// absolute content size or content offset with lazy stacks, since these are estimated and
/// unstable"* (WWDC26 session 321). The remaining fix is an engine whose anchor is a row, not a
/// number; this type is what holds the line until then.
///
/// The same gap is what the owner's report is made of. A `LazyVStack` reports the height of
/// the rows it has measured, so a conversation whose content lands *after* the first layout
/// — a thread whose replies arrive a relay round trip later, a channel opened before its
/// backfill — comes to rest at the bottom of a height that was never the real one. Measured,
/// opening the same 50-message conversation while the local store held only the first few
/// rows:
///
/// | rows the prime found | landed on | should be |
/// |---|---|---|
/// | 1 | 1049 (newest) | ✓ |
/// | 3 | **1000** | 1049 |
/// | 5 | **1002** | 1049 |
/// | 10 | **1007** | 1049 |
/// | 20 | 1049 | ✓ |
///
/// Non-monotonic, because it turns on how much of the stack had been measured at that
/// instant — which is why the report is "sometimes". And the surface is left believing the
/// reader is away from the bottom, so the tail freezes and later arrivals are held back
/// too: the conversation stops updating until the reader scrolls down, which is the other
/// half of the same report.
///
/// # The rule
///
/// One invariant for both halves: **the distance to the newest message is what survives a
/// content change.** Until the reader has moved the conversation themselves that distance
/// is zero by definition — a conversation opens at its newest message and stays there
/// however the content settles underneath it.
///
/// # Why a *declared* content change and not a measured one
///
/// The first version of this file took "the content changed" to mean `contentSize.height`
/// changed, and that premise is false for the same reason the rest of this note is about: a
/// `LazyVStack` estimates the rows it has not measured, so its reported height *also* moves
/// when nothing was inserted at all — when the container changes, and as rows materialise
/// under a scroll. Every one of those readings was taken for an insertion, and the
/// estimation error was applied to the reader as a scroll. Measured on iPhone 17 Pro /
/// iOS 26 in `~/.buzz/.scratch/scrollharness`, driving the keyboard up and down under a
/// reader parked in history. A *jump* is one frame in which the offset moved with no finger
/// on the list:
///
/// | run | correcting on a measured change | correcting on a declared one |
/// |---|---|---|
/// | 20 keyboard show/hides | 32 jumps, biggest −3925, reader **7 messages back** | **0**, offset 41868 → 41868 |
/// | 10 slower show/hides | 18 jumps, biggest **−15750**, reader 5 messages back | **0**, offset 41910 → 41910 |
/// | 3 background → foreground | 6 jumps: 32559 → 32699 → 32459 → 32220 | **0**, offset unchanged every cycle |
///
/// Raising the keyboard alone moved the measured height by **+3702 points** with not one row
/// added. So the owner declares it instead: ``contentDidChange()`` opens a settling window,
/// and outside that window a height change means the stack re-measured and means nothing to
/// the reader.
///
/// # Why the reference is latched rather than read from the previous reading
///
/// A `LazyVStack` does not arrive at its height once; it re-measures as rows materialise,
/// so one page load produces a *run* of height changes. Correcting against the reading
/// before this one makes each correction the reference for the next, and measured that way
/// two of three page loads held the reader and the third drifted thirty rows — the
/// corrections were chasing a moving reference. The distance is taken while the height is
/// holding still, which is when it is the reader's own, and every correction in a settling
/// run aims at that one number.
///
/// # Not observable, and not a struct
///
/// ``correction(for:atBottomSlack:)`` runs on every scrolled frame and writes to this on
/// most of them. As `@State` values that would invalidate the whole shell — message list
/// included — once per frame of every scroll. Nothing renders any of it.
@MainActor
final class ConversationReaderPlace {
    /// What the content measured and where the window onto it sits, read at one instant so
    /// the three cannot disagree.
    struct Span: Equatable {
        let contentHeight: CGFloat
        /// The scroll view's own `contentOffset.y`.
        let offset: CGFloat
        /// From the newest message: `contentSize.height - visibleRect.maxY`, the same
        /// measure ``ConversationScaffold`` bands on.
        let distance: CGFloat

        /// Whether this reading is made of numbers at all. A scroll view mid-layout can
        /// report an infinite `visibleRect`, and every arithmetic result below inherits it.
        var isFinite: Bool { contentHeight.isFinite && offset.isFinite && distance.isFinite }
    }

    /// What opened the settling window, which is what decides the rule applied across it.
    ///
    /// The two differ over exactly one reader — the one parked in history — and they differ
    /// because the question is not the same. See ``rowDidChangeInPlace()``.
    private enum Change {
        /// Rows arrived, an older page was inserted, a row was pruned. Content above the
        /// reader may have moved, so their distance to the newest message is what has to
        /// survive.
        case structural
        /// A row already in the list changed height where it stands. Nothing above it moved,
        /// so the offset the reader is on already is their place.
        case inPlace
    }

    /// What a reading asks the scroll view to do.
    enum Correction: Equatable {
        case none
        /// Land on the newest message.
        case bottom
        /// Land at this `contentOffset.y`.
        case offset(CGFloat)
    }

    /// Whether a finger is on the list, or a scroll it started is still running. Nothing is
    /// corrected while this is true: a correction mid-drag fights the reader, and the
    /// arrival that would want one cannot happen there — the tail freeze holds new messages
    /// back for exactly as long as the reader is away from the bottom.
    var isScrolling = false
    /// Whether the reader has ever moved this conversation themselves — by dragging it, or
    /// by taking the pill to a particular message.
    var hasMoved = false
    /// Whether a jump to the newest message is still animating — see ``scrollCameToRest()``.
    ///
    /// Readable by the scaffold because one other decision has to know it: the band observer
    /// that reports *whether the newest row is in view*, which the owner turns into the tail
    /// freeze. A jump to the newest message begins, by definition, somewhere that is not the
    /// bottom, so the first readings it produces say "away from the newest message" — and
    /// believing them re-freezes the tail underneath a trip whose whole purpose is to reach
    /// it. See ``ConversationScaffold``'s `Edges` observer for what that costs an own send.
    ///
    /// One exposure, deliberately left: a jump issued to a reader who is *already* at the
    /// newest row moves nothing, so no scroll phase change is delivered and this is never
    /// cleared until they take hold of the list. It is benign because it travels with
    /// ``hasMoved`` being `false` — the state in which this whole file already holds them at
    /// the newest message — and because the jumps that reach here are asked for by a reader
    /// who is not at the bottom (``ChannelTimelineModel/shouldJumpToOwnSend``).
    private(set) var isLandingOnNewest = false

    /// The distance last seen while the height was holding still and no settling window was
    /// open — the reader's own place, as opposed to a place a correction put them in.
    private(set) var anchoredDistance: CGFloat?
    private var last: Span?
    /// Readings left in the window opened by ``contentDidChange()``. Zero means the height
    /// belongs to content nobody changed, and a change in it is the stack re-measuring.
    private var settling = 0
    /// Consecutive readings whose height matched the one before. The window closes on a run
    /// of these rather than on the first one: the reading that follows a commit is not
    /// guaranteed to be the one carrying the new height.
    private var stableRun = 0
    /// What the open window was opened for. Read once, at the end of ``correction(for:atBottomSlack:)``,
    /// and only for the reader it separates.
    private var change: Change = .structural

    /// Below this, a correction is not worth a frame.
    private static let tolerance: CGFloat = 0.5
    /// How long a settling window may stay open. A page load re-measures for a handful of
    /// frames; this is about a second at 60Hz, so a stack that never settles — one being
    /// scrolled the whole time — cannot hold the window open indefinitely.
    private static let settlingReadings = 60
    /// How still the height must be for the window to close. Three frames: long enough not
    /// to close on a single coincidence mid-run, short enough that the next real change is
    /// treated as its own.
    private static let stableReadingsToSettle = 3

    /// The owner's rendered content changed — rows arrived, an older page was inserted, a
    /// row was pruned. The readings that follow are the *new* content being measured, and
    /// the reader's place has to be carried across them.
    ///
    /// Idempotent, and cheap to over-call: a commit that changes no height simply closes the
    /// window again on the next few readings without correcting anything.
    ///
    /// The one case this leaves open is a *storm* of commits — a window reopened faster than
    /// three readings can close it — during which a re-measure would still be corrected.
    /// Left as is because the storm cases are already the ones that want correcting: rows
    /// arriving while the reader is at the bottom belong at the bottom, and rows arriving
    /// while they are away are held behind the tail freeze and commit nothing.
    func contentDidChange() {
        change = .structural
        settling = Self.settlingReadings
        // The run that closes a window has to be a run measured *inside* it. Without this
        // the stillness before the commit counts toward it, and the window shuts on the
        // first reading — before the new content has been measured at all, which is the one
        // moment it exists to cover.
        stableRun = 0
    }

    /// A row already in the list changed height where it stands — a reaction chip appeared or
    /// went away, a mention resolved, a reply summary changed. Nothing was added, removed or
    /// reordered.
    ///
    /// This is a different question from ``contentDidChange()``, and for a reader parked in
    /// history it wants the opposite answer. The rule that carries them across an *insertion*
    /// is that the distance to the newest message survives it, because a page landing above
    /// them moves everything they are looking at down by its own height. A chip appearing on
    /// a message they can see moves nothing above it — the growth is entirely below the row it
    /// is on — so the offset they are already on *is* their place, and correcting toward a
    /// distance pushes them down by the growth. That is the reported jump.
    ///
    /// The size of it is not the chip. A `LazyVStack` sizes every row it has not measured at
    /// the average of the ones it has, so one row changing height re-estimates the whole
    /// extent — and the extent is what the distance is derived from. A 28-point chip can move
    /// `contentSize.height` by hundreds, which is why the jump reads as arbitrary rather than
    /// as a nudge, and why this is the one rule here that reads no estimated number at all.
    ///
    /// A structural window already open outranks this: a page really did land above the
    /// reader, and that correction must not be traded away by a reaction arriving in the same
    /// breath. The reverse is safe — a row growing inside a structural window is covered by
    /// the distance rule, slightly wrongly and by one chip.
    ///
    /// Knowingly wrong in one place: a chip landing on a row *above* the reader's viewport
    /// does move what they are looking at, by its own height, and nothing here corrects it.
    /// The error is bounded by one chip, about 28 points, once; the only correction available
    /// is arithmetic on the estimated extent, whose error is unbounded and was the defect.
    func rowDidChangeInPlace() {
        guard settling == 0 || change == .inPlace else { return }
        change = .inPlace
        settling = Self.settlingReadings
        stableRun = 0
    }

    /// The reader took hold of the list themselves — a drag, or the deceleration one left
    /// behind.
    ///
    /// Their place is theirs from this moment, so a jump still in flight is overruled here
    /// rather than where it would have ended. That distinction is the tail freeze's: while a
    /// jump is in flight the band observer declines to re-freeze (see ``isLandingOnNewest``),
    /// and someone who grabs the list mid-flight and pulls back into history has to be able to
    /// re-arm it — but a conversation they have brought to rest produces no further readings
    /// for the observer to act on. Ending the flight at rest instead leaves the tail released
    /// under a reader who is plainly reading history.
    ///
    /// ``scrollCameToRest()`` reads the same as it did: a flight the reader overruled was
    /// already answered `.none` by ``hasMoved``.
    func readerTookHold() {
        hasMoved = true
        isLandingOnNewest = false
    }

    /// A jump to the newest message has just been issued.
    ///
    /// It makes the reader, by the definition this whole file works to, someone who is not
    /// parked in history — so ``hasMoved`` is cleared and the invariant above applies to them
    /// again: *a conversation nobody has moved belongs at its newest message.*
    ///
    /// Without that the jump is undone. ``correction(for:atBottomSlack:)`` corrects toward
    /// ``anchoredDistance``, which is still the distance the reader had *before* the jump —
    /// the window it was measured in has no reason to have closed — so the first content
    /// change to arrive afterwards takes them back to it. An own send is exactly that shape:
    /// the row the jump is aimed at commits a moment *after* the jump, and the correction
    /// greeting it is what springs the author back up into the history they were reading.
    ///
    /// The reader's own drag re-arms `hasMoved` if they take hold of the list — see
    /// ``ConversationScaffold``'s scroll-phase observer, which sets it for every phase but the
    /// animated one this jump runs in.
    func jumpToNewestBegan() {
        hasMoved = false
        isLandingOnNewest = true
    }

    /// A scroll has come to rest. Says whether the jump that started it still has work to do.
    ///
    /// # Why a jump has to be asserted twice
    ///
    /// "The newest message" is resolved against the newest row *that exists when the jump is
    /// issued*, and the case this surface exists to serve has a newer one arriving a moment
    /// later: an author sends, and the row is signed and committed a beat after the tap, by
    /// which time the scroll aimed at what was newest *then* is already in flight. The owner
    /// does ask again when the row lands (``ChannelTimelineModel/landOnOwnSend(among:)``) —
    /// but that ask arrives *during* the animation, and neither of the two things that would
    /// serve it can act there: a `scrollTo` issued into an in-flight animated scroll has no
    /// visible effect, and ``correction(for:atBottomSlack:)`` refuses everything while
    /// ``isScrolling``, spending the new row's own height change on a reading it cannot use.
    ///
    /// Measured on iPhone 17 Pro / iOS 26, `thread-8-longopener`, same commit, four runs:
    /// three landed on the message that had just been sent and one landed on the row that had
    /// been newest at the tap, leaving the message 67 points below the readable band. The
    /// three are the runs where the commit happened to land after the animation had ended.
    ///
    /// So the destination is asserted once more at rest, where the newest row is whatever it
    /// now really is and has a real frame to be scrolled to. In the ordinary case it is a
    /// no-op: the scroll view is already there.
    ///
    /// ``hasMoved`` is the guard, and it is exact — ``jumpToNewestBegan()`` clears it as the
    /// jump starts and the reader's own drag sets it again, so someone who took hold of the
    /// list mid-flight is left where they put it.
    func scrollCameToRest() -> Correction {
        guard isLandingOnNewest else { return .none }
        isLandingOnNewest = false
        return hasMoved ? .none : .bottom
    }

    /// Reads one geometry sample and says what it implies.
    ///
    /// - Parameter atBottomSlack: the band the scaffold counts as *at* the newest message.
    func correction(for span: Span, atBottomSlack: CGFloat) -> Correction {
        // An unresolved layout hands back a non-finite rect, and an offset computed from one
        // reaches `CALayer` as a NaN position — which is a crash, not a misplaced reader.
        // The same guard `dismissesSuggestionsOnScroll` carries, for the same reason.
        //
        // It is dropped rather than recorded: a reading that is not a number is not a state
        // to compare the next one against either, and keeping it would make the reading
        // after it look like a height change and skip a refresh of the reference.
        guard span.isFinite else { return .none }
        let previous = last
        last = span
        // Nothing to compare the first reading against, and a scroll view mid-first-layout
        // reports a zero height that means "not measured yet" rather than "empty".
        guard let previous, previous.contentHeight > 0 else { return .none }
        guard span.contentHeight != previous.contentHeight else {
            stableRun += 1
            if stableRun >= Self.stableReadingsToSettle { settling = 0 }
            // The reference is only refreshed once the window has closed. Inside one it must
            // stay put — a `LazyVStack` arrives at its height in instalments, and a reference
            // that follows the instalments is a reference chasing itself (measured: two of
            // three page loads held, the third drifted thirty rows).
            //
            // A finger on the list is the exception, and not really one: nothing is corrected
            // while the reader is scrolling, so where they have put the conversation *is*
            // their place, window or no window.
            if settling == 0 || isScrolling { anchoredDistance = span.distance }
            return .none
        }
        stableRun = 0
        // The height moved with no commit behind it: the stack re-measured content nobody
        // changed. Correcting here is what moved the reader on every keyboard and every app
        // switch — see the table above.
        guard settling > 0 else { return .none }
        settling -= 1
        guard !isScrolling else { return .none }
        // A conversation nobody has moved belongs at its newest message, and so does one
        // whose reader is already there. Both rules agree about them, and separate only
        // over the reader below.
        guard hasMoved, let anchored = anchoredDistance, anchored > atBottomSlack else {
            return .bottom
        }
        // A row grew where it stands: nothing above it moved, so the offset this reader is
        // already on is their place, and leaving it alone is the whole of the expected
        // behaviour — *content above the reacted message must stay in place*. See
        // ``rowDidChangeInPlace()`` for why correcting here moves them by far more than the
        // chip that caused it.
        guard change == .structural else { return .none }
        // Raising the offset by `d` lowers the distance to the bottom by `d`, so this is
        // the offset at which the distance is the one the reader had. A correction toward
        // the invariant rather than a delta applied to it, so a height that arrives in
        // instalments converges, and a change the framework did adjust for costs one
        // comparison and no movement.
        let correction = span.distance - anchored
        guard abs(correction) > Self.tolerance else { return .none }
        return .offset(span.offset + correction)
    }
}
