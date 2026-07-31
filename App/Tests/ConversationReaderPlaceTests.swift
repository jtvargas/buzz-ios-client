import CoreGraphics
@testable import Hive
import Testing

/// What a change in the content's height does to the reader's place.
///
/// Every case here is a sequence of geometry readings, because that is what the scroll
/// view produces and because the first bug this replaced was in the *sequence*: correcting
/// against the reading before the current one made each correction the reference for the
/// next, and a `LazyVStack` re-measures several times per page load.
///
/// The second bug was in the *premise*, and half of this suite is about it: a height that
/// changed is not content that changed. A `LazyVStack` re-measures unchanged rows whenever
/// the container moves — the keyboard, an app-switcher snapshot — so a correction owes
/// itself to ``ConversationReaderPlace/contentDidChange()``, which the owner calls when it
/// really did commit something.
///
/// Deliberately not here: that `defaultScrollAnchor(.bottom, for: .sizeChanges)` fails to
/// do this at all, and the sizes of the two failures above. Those are facts about SwiftUI
/// and about a device, settled in a harness around the shipping ``ConversationScaffold``
/// (`~/.buzz/.scratch/scrollharness`) and recorded on ``ConversationReaderPlace``.
@MainActor
@Suite("Conversation reader place", .timeLimit(.minutes(1)))
struct ConversationReaderPlaceTests {
    private let slack: CGFloat = 8

    private func span(height: CGFloat, offset: CGFloat, distance: CGFloat) -> ConversationReaderPlace.Span {
        ConversationReaderPlace.Span(contentHeight: height, offset: offset, distance: distance)
    }

    private func feed(
        _ place: ConversationReaderPlace,
        _ spans: [ConversationReaderPlace.Span]
    ) -> [ConversationReaderPlace.Correction] {
        spans.map { place.correction(for: $0, atBottomSlack: slack) }
    }

    /// Parks a reader at `distance` with the height holding still, and leaves no settling
    /// window open — the state a conversation is in between commits.
    ///
    /// Four readings rather than two: the window closes on a *run* of unchanged heights, and
    /// the reference is only refreshed once it has.
    private func park(_ place: ConversationReaderPlace, height: CGFloat, offset: CGFloat, distance: CGFloat) {
        _ = feed(place, Array(repeating: span(height: height, offset: offset, distance: distance), count: 4))
    }

    // MARK: - Nothing to correct against

    @Test("the first reading corrects nothing")
    func firstReading() {
        let place = ConversationReaderPlace()
        place.contentDidChange()
        #expect(place.correction(for: span(height: 5_000, offset: 4_000, distance: 0), atBottomSlack: slack) == .none)
    }

    @Test("a height of zero is 'not measured yet', not 'empty'")
    func unmeasuredContent() {
        // A scroll view mid-first-layout reports zero, and the height that follows it is
        // the first real one — not a change to correct for.
        let place = ConversationReaderPlace()
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: 0, offset: 0, distance: 0),
            span(height: 5_000, offset: 4_000, distance: 0),
        ])
        #expect(corrections == [.none, .none])
    }

    @Test("a reading that is not made of numbers is ignored")
    func nonFiniteGeometry() {
        // An unresolved layout hands back an infinite `visibleRect`, and an offset computed
        // from one reaches `CALayer` as a NaN position — a crash, not a misplaced reader.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: .infinity, offset: 30_000, distance: -.infinity),
            span(height: 60_000, offset: .nan, distance: 21_000),
        ])
        #expect(corrections == [.none, .none])
    }

    @Test("a reading that is not made of numbers is not what the next one is compared against")
    func nonFiniteIsNotAReference() {
        // Recording it would make the reading after it look like a height change — and one
        // with no commit behind it, so the reference would go un-refreshed for a frame.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        _ = feed(place, [span(height: .infinity, offset: .infinity, distance: .infinity)])
        // The reader drags to a new place, and the height holds still there.
        park(place, height: 40_000, offset: 25_000, distance: 6_000)
        place.contentDidChange()
        // A page arrives: the correction must aim at 6_000, the place they are actually in.
        #expect(feed(place, [span(height: 60_000, offset: 25_000, distance: 26_000)]) == [.offset(45_000)])
    }

    @Test("a height that holds still asks for nothing")
    func stableHeight() {
        let place = ConversationReaderPlace()
        let corrections = feed(place, [
            span(height: 5_000, offset: 4_000, distance: 0),
            span(height: 5_000, offset: 3_000, distance: 1_000),
            span(height: 5_000, offset: 2_000, distance: 2_000),
        ])
        #expect(corrections == [.none, .none, .none])
    }

    // MARK: - A height that moved with no commit behind it

    @Test("the stack re-measuring unchanged content moves nobody")
    func reMeasureIsNotAContentChange() {
        // The regression this suite exists for. Raising the keyboard changed the measured
        // height of a 50-message conversation by +3702 points with not one row added, and
        // correcting that drift moved the reader seven messages back over twenty
        // show/hides.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        let corrections = feed(place, [
            span(height: 43_702, offset: 33_702, distance: 1_000),
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 43_702, offset: 33_702, distance: 1_000),
        ])
        #expect(corrections == [.none, .none, .none])
    }

    @Test("a conversation nobody has moved is not pinned to the bottom by a re-measure")
    func reMeasureDoesNotPinToBottom() {
        // The same premise from the other side: without a commit behind it, a height change
        // must not drag a reader to the newest message either.
        let place = ConversationReaderPlace()
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        #expect(feed(place, [span(height: 43_702, offset: 30_000, distance: 4_702)]) == [.none])
    }

    @Test("a window opened after a still run does not shut on the stillness before it")
    func windowIgnoresEarlierStillness() {
        // A commit arrives against a conversation that has been sitting still, and the first
        // reading after it carries an unchanged height — the scroll view reporting an offset
        // change before the new rows have been measured. The window must survive that, or it
        // covers nothing.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_882, offset: 44_300, distance: 1_000)
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: 45_882, offset: 44_300, distance: 1_000),
            span(height: 80_338, offset: 44_300, distance: 35_456),
        ])
        #expect(corrections == [.none, .offset(78_756)])
    }

    @Test("the window closes once the height has settled")
    func windowCloses() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        // The commit's own settling run, then three readings that agree.
        _ = feed(place, [
            span(height: 60_000, offset: 30_000, distance: 21_000),
            span(height: 50_000, offset: 49_000, distance: 1_000),
            span(height: 50_000, offset: 49_000, distance: 1_000),
            span(height: 50_000, offset: 49_000, distance: 1_000),
        ])
        // A keyboard, after the window closed.
        #expect(feed(place, [span(height: 53_702, offset: 52_702, distance: 1_000)]) == [.none])
    }

    // MARK: - A conversation nobody has moved

    @Test("content arriving after the first layout lands on the newest message")
    func lateFillGoesToTheBottom() {
        // The report: a thread primes with its opener alone, and the replies land a relay
        // round trip later against a height the stack had never measured.
        let place = ConversationReaderPlace()
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: 600, offset: -116, distance: -558),
            span(height: 12_240, offset: 66, distance: 11_300),
        ])
        #expect(corrections == [.none, .bottom])
    }

    @Test("a height that settles in instalments lands on the newest message every time")
    func settlingGoesToTheBottom() {
        let place = ConversationReaderPlace()
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: 600, offset: -116, distance: -558),
            span(height: 4_000, offset: 66, distance: 3_100),
            span(height: 9_500, offset: 3_100, distance: 5_500),
            span(height: 12_240, offset: 11_400, distance: 40),
        ])
        #expect(corrections == [.none, .bottom, .bottom, .bottom])
    }

    @Test("a reader already at the newest message is put back on it")
    func atBottomStaysAtBottom() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 5_000, offset: 4_000, distance: 0)
        // A message arrives.
        place.contentDidChange()
        #expect(feed(place, [span(height: 5_400, offset: 4_000, distance: 400)]) == [.bottom])
    }

    // MARK: - A reader who has moved

    @Test("an older page arriving above a reader restores their distance from the newest")
    func olderPageRestoresDistance() {
        // The measured failure: 50 rows inserted above, the raw offset kept, the reader a
        // whole page backwards.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_882, offset: 44_300, distance: 1_000)
        place.contentDidChange()
        let corrections = feed(place, [span(height: 80_338, offset: 44_300, distance: 35_456)])
        // 44_300 + (35_456 - 1_000): the offset at which the distance to the newest
        // message is the one they had.
        #expect(corrections == [.offset(78_756)])
    }

    @Test("a settling run aims at one reference instead of chasing itself")
    func settlingDoesNotDrift() {
        // Three height changes for one page load, with no stable reading between them —
        // which is what a `LazyVStack` produces. Each correction must target the distance
        // the reader actually had, not the one the previous correction produced.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        let corrections = feed(place, [
            span(height: 60_000, offset: 30_000, distance: 21_000),
            span(height: 70_000, offset: 50_000, distance: 11_000),
            span(height: 74_000, offset: 60_000, distance: 5_000),
        ])
        #expect(corrections == [
            .offset(50_000), // 30_000 + (21_000 - 1_000)
            .offset(60_000), // 50_000 + (11_000 - 1_000)
            .offset(64_000), // 60_000 + (5_000 - 1_000)
        ])
        // All three name the same place: an offset whose distance to the newest message is
        // the reader's own 1_000.
        #expect(place.anchoredDistance == 1_000)
    }

    @Test("a correction smaller than half a point is not worth a frame")
    func toleranceHoldsStill() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        #expect(feed(place, [span(height: 40_000.3, offset: 30_000, distance: 1_000.3)]) == [.none])
    }

    // MARK: - Who is allowed to move the list

    @Test("nothing is corrected while the reader is scrolling")
    func scrollingIsLeftAlone() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        place.isScrolling = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        #expect(feed(place, [span(height: 60_000, offset: 30_000, distance: 21_000)]) == [.none])
    }

    // MARK: - The keyboard taking room at the bottom

    @Test("a keyboard lands a conversation nobody has moved on its newest message")
    func keyboardRoomPinsAnUnmovedReader() {
        // The owner's report: tapping the composer raised the keyboard over the newest
        // message. The keyboard takes points off the bottom of the scrollable region, and
        // nothing was putting them back.
        let place = ConversationReaderPlace()
        park(place, height: 5_000, offset: 4_000, distance: 0)
        #expect(place.keyboardRoomDidChange(isAtBottom: true) == .bottom)
    }

    @Test("a reader who came back to the newest message is carried too")
    func keyboardRoomPinsAReaderAtTheBottom() {
        // `hasMoved` is sticky for the life of the conversation — one drag sets it and
        // nothing clears it — so it cannot be the whole predicate. A reader who scrolled up
        // and then came back down is at the newest message and wants the same behaviour as
        // one who never left.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 5_000, offset: 4_000, distance: 0)
        #expect(place.keyboardRoomDidChange(isAtBottom: true) == .bottom)
    }

    @Test("a reader parked in history is not moved by the keyboard")
    func keyboardRoomLeavesHistoryAlone() {
        // The owner's own scope — "if the user has scrolled up at all, no push is required" —
        // and the failure mode this whole file exists to prevent: what they are reading is
        // nowhere near the bottom edge, so taking room at an end they are not looking at may
        // not move them.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 9_000)
        #expect(place.keyboardRoomDidChange(isAtBottom: false) == .none)
    }

    @Test("the keyboard is ignored while the reader is scrolling")
    func keyboardRoomWaitsForTheDragToEnd() {
        // A finger on the list outranks it, exactly as it does on a content change: a
        // correction mid-drag fights the reader. This is also the interactive keyboard
        // dismissal, where the room above the keyboard changes on every frame of a drag.
        let place = ConversationReaderPlace()
        place.isScrolling = true
        #expect(place.keyboardRoomDidChange(isAtBottom: true) == .none)
    }

    @Test("room being given back is the same decision as room being taken")
    func keyboardRoomIsSymmetric() {
        // The decision is about where the reader is, not about which way the room went — a
        // keyboard dismissed gives the region its points back, and the newest message belongs
        // against the composer either way.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 5_000, offset: 4_000, distance: 0)
        #expect(place.keyboardRoomDidChange(isAtBottom: true) == .bottom)
        park(place, height: 40_000, offset: 30_000, distance: 9_000)
        #expect(place.keyboardRoomDidChange(isAtBottom: false) == .none)
    }

    @Test("the keyboard changing is not a content change")
    func keyboardRoomOpensNoSettlingWindow() {
        // The re-pin is immediate and self-contained. If it opened a settling window instead,
        // every keyboard raise would arm the correction path for sixty readings — and that path
        // corrects height changes the stack invented, which is how a reader in history gets
        // moved 800 points by a 311-point keyboard.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        _ = place.keyboardRoomDidChange(isAtBottom: true)
        // A re-measure with no commit behind it, immediately after: still nothing.
        #expect(feed(place, [span(height: 43_702, offset: 33_702, distance: 1_000)]) == [.none])
    }

    @Test("a drag mid-settle still updates where the reader is")
    func draggingUpdatesTheReference() {
        // The reference is taken from readings where the height held still, and those
        // happen during a drag too — otherwise a reader who scrolled and then received a
        // page would be restored to where they were before the drag. That has to hold with
        // a settling window open, which is exactly when a page is arriving.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 40_000, offset: 30_000, distance: 1_000)
        place.contentDidChange()
        place.isScrolling = true
        _ = feed(place, [span(height: 40_000, offset: 25_000, distance: 6_000)])
        place.isScrolling = false
        #expect(feed(place, [span(height: 60_000, offset: 25_000, distance: 26_000)]) == [.offset(45_000)])
    }

    @Test("a jump to the newest message asserts its destination again when the scroll rests")
    func aJumpIsAssertedAgainAtRest() {
        // The newest row can change *during* the jump — an own send is signed and committed a
        // beat after the tap — and neither a `scrollTo` into an in-flight animation nor a
        // correction (refused while `isScrolling`) can act on that. So the destination is
        // asked for once more at rest, where the newest row is whatever it now really is.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        place.jumpToNewestBegan()
        #expect(!place.hasMoved)
        #expect(place.scrollCameToRest() == .bottom)

        // Once, not on every scroll that ever comes to rest.
        #expect(place.scrollCameToRest() == .none)
    }

    @Test("a reader who takes hold of the list mid-jump is left where they put it")
    func aDragDuringAJumpWins() {
        let place = ConversationReaderPlace()
        place.jumpToNewestBegan()
        // What ``ConversationScaffold``'s scroll-phase observer does for any phase the reader
        // caused. The jump is theirs to overrule from the moment they touch it.
        place.hasMoved = true
        #expect(place.scrollCameToRest() == .none)
    }

    @Test("a scroll that no jump started asks for nothing")
    func anOrdinaryScrollRestsWithoutCorrecting() {
        let place = ConversationReaderPlace()
        #expect(place.scrollCameToRest() == .none)
    }
}
