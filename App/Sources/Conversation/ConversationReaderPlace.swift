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
/// page backwards. Removing `.scrollPosition` and removing the `.sizeChanges` anchor were
/// each measured separately and together: all four variants behave identically, so neither
/// modifier owns this and neither can be traded for it.
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
        settling = Self.settlingReadings
        // The run that closes a window has to be a run measured *inside* it. Without this
        // the stillness before the commit counts toward it, and the window shuts on the
        // first reading — before the new content has been measured at all, which is the one
        // moment it exists to cover.
        stableRun = 0
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
        // whose reader is already there.
        guard hasMoved, let anchored = anchoredDistance, anchored > atBottomSlack else {
            return .bottom
        }
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
