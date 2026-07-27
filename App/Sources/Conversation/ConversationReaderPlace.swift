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

    /// The distance last seen while the height was holding still.
    private(set) var anchoredDistance: CGFloat?
    private var last: Span?

    /// Below this, a correction is not worth a frame.
    private static let tolerance: CGFloat = 0.5

    /// Reads one geometry sample and says what it implies.
    ///
    /// - Parameter atBottomSlack: the band the scaffold counts as *at* the newest message.
    func correction(for span: Span, atBottomSlack: CGFloat) -> Correction {
        defer { last = span }
        // Nothing to compare the first reading against, and a scroll view mid-first-layout
        // reports a zero height that means "not measured yet" rather than "empty".
        guard let previous = last, previous.contentHeight > 0 else { return .none }
        guard span.contentHeight != previous.contentHeight else {
            // The height is holding still, so wherever the reader is, is where they mean to
            // be. Taken mid-drag too: that is how a drag updates the reference.
            anchoredDistance = span.distance
            return .none
        }
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
