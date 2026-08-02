import CoreGraphics
@testable import Hive
import Testing

/// What ``ConversationReaderPlace`` does about a change it is *told the cause of*.
///
/// Its neighbour suite covers the readings themselves — a height that moved, and whether
/// anything committed behind it. These are the two cases where the height moving is not the
/// question at all, and where taking one for the other is a defect a reader can see:
///
/// - a row that changed height **where it stands**, which moves nothing above it, so a
///   reader in history must not be moved at all;
/// - a jump to the newest row **in flight**, whose own first readings say "away from the
///   bottom" and must not be read as the reader having gone back to history.
///
/// Both are the owner's report of 2026-07-31: reacting to an older message threw the list
/// somewhere unexpected, and sending from deep in history did not arrive on the message that
/// had just been sent.
@MainActor
@Suite("Conversation reader place, by cause", .timeLimit(.minutes(1)))
struct ConversationReaderCauseTests {
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

    /// Parks a reader with the height holding still and no settling window open — see the
    /// neighbour suite, which explains why four readings and not two.
    private func park(_ place: ConversationReaderPlace, height: CGFloat, offset: CGFloat, distance: CGFloat) {
        _ = feed(place, Array(repeating: span(height: height, offset: offset, distance: distance), count: 4))
    }

    // MARK: - A row that grew where it stands

    @Test("a chip appearing on a message a reader can see leaves them exactly where they are")
    func inPlaceGrowthHoldsAReaderInHistory() {
        // The reported defect. Reacting to an older message pushed the reader down, because
        // the growth below the reacted row raises the distance to the newest message and the
        // insertion rule spends that raise as a scroll.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_000, offset: 30_000, distance: 1_000)
        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 45_028, offset: 30_000, distance: 1_028)]) == [.none])
    }

    @Test("a chip is not measured in chips: the whole estimated extent moves with one row")
    func inPlaceGrowthIsNotTheSizeOfTheChip() {
        // Why the jump read as arbitrary rather than as a nudge. A `LazyVStack` sizes every
        // row it has not measured at the average of the ones it has, so a 28-point chip
        // re-estimates the whole extent — here by 4 000. Under the insertion rule that is a
        // 4 000-point scroll for a reader who should not have moved at all.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_000, offset: 30_000, distance: 1_000)
        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 49_000, offset: 30_000, distance: 5_000)]) == [.none])
    }

    @Test("a reader resting on the newest message is carried by a chip landing on it")
    func inPlaceGrowthCarriesAReaderAtTheBottom() {
        // For them the growth *is* the message they are looking at sliding under the
        // composer, which is the one case where moving them is the expected behaviour.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_000, offset: 44_000, distance: 0)
        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 45_028, offset: 44_000, distance: 28)]) == [.bottom])
    }

    @Test("a conversation nobody has moved is carried too")
    func inPlaceGrowthCarriesAnUnmovedReader() {
        let place = ConversationReaderPlace()
        park(place, height: 45_000, offset: 44_000, distance: 0)
        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 45_028, offset: 44_000, distance: 28)]) == [.bottom])
    }

    @Test("a page landing above the reader outranks a chip arriving in the same breath")
    func structuralChangeOutranksAnInPlaceOne() {
        // Both can be committed in one turn — the store raises rows and reactions on the
        // same observation. The insertion is the one that moved content above the reader, so
        // its correction must survive; losing it is the older page throwing them backwards.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_882, offset: 44_300, distance: 1_000)
        place.contentDidChange()
        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 80_338, offset: 44_300, distance: 35_456)]) == [.offset(78_756)])
    }

    @Test("a page landing after a chip claims the window from it")
    func structuralChangeTakesOverAnInPlaceWindow() {
        // The other order. Nothing has been measured yet when the second call arrives, so the
        // window belongs to whichever change is the more consequential — the insertion.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_882, offset: 44_300, distance: 1_000)
        place.rowDidChangeInPlace()
        place.contentDidChange()
        #expect(feed(place, [span(height: 80_338, offset: 44_300, distance: 35_456)]) == [.offset(78_756)])
    }

    @Test("a chip still needs a window: a re-measure with nothing declared moves nobody")
    func inPlaceGrowthClosesItsWindow() {
        // The window closes on a run of unchanged heights exactly as an insertion's does, so
        // a keyboard arriving afterwards is not spent as the chip settling.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_000, offset: 30_000, distance: 1_000)
        place.rowDidChangeInPlace()
        park(place, height: 45_028, offset: 30_000, distance: 1_028)
        #expect(feed(place, [span(height: 48_730, offset: 30_000, distance: 4_730)]) == [.none])
        // And the reader's place is now the one the chip left them in.
        #expect(place.anchoredDistance == 1_028)
    }

    // MARK: - A jump the engine itself issued

    @Test("a jump in flight is visible, so its own readings are not read as the reader's place")
    func aJumpInFlightIsVisibleToTheBandObserver() {
        // A jump to the newest message begins somewhere that is not the bottom, so the first
        // readings it produces say "away from the newest message". ``ConversationScaffold``'s
        // band observer turns that into the owner's tail freeze, and re-freezing here holds
        // back the very message the trip is going to fetch — an own send from deep in history
        // is exactly that shape. The flag is what lets the observer tell the trip apart from a
        // reader who went back to reading.
        let place = ConversationReaderPlace()
        #expect(!place.isLandingOnNewest)
        place.jumpToNewestBegan()
        #expect(place.isLandingOnNewest)
        // It lasts precisely as long as the flight: cleared where the flight ends, which is
        // the same reading that asserts the destination once more.
        #expect(place.scrollCameToRest() == .bottom)
        #expect(!place.isLandingOnNewest)
    }

    @Test("a reader who takes hold of the list mid-jump is left where they put it")
    func aDragDuringAJumpWins() {
        let place = ConversationReaderPlace()
        place.jumpToNewestBegan()
        // What ``ConversationScaffold``'s scroll-phase observer does for any phase the reader
        // caused. The jump is theirs to overrule from the moment they touch it.
        place.readerTookHold()
        #expect(place.scrollCameToRest() == .none)
        // And the flight ends there rather than at rest, so the band observer can re-arm the
        // owner's tail freeze while the drag runs — a list brought to rest in history
        // produces no further reading for it to act on.
        #expect(!place.isLandingOnNewest)
    }

    // MARK: - A message landing

    @Test("a message landing suppresses both settling paths until rest")
    func aMessageLandingSuppressesStructuralAndInPlaceCorrections() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        park(place, height: 45_000, offset: 30_000, distance: 1_000)
        place.jumpToMessageBegan()

        place.contentDidChange()
        #expect(feed(place, [span(height: 49_000, offset: 30_000, distance: 5_000)]) == [.none])

        place.rowDidChangeInPlace()
        #expect(feed(place, [span(height: 49_028, offset: 30_000, distance: 5_028)]) == [.none])
    }

    @Test("a message landing reasserts its row and anchors the resting distance")
    func aMessageLandingIsReassertedAtRest() {
        let place = ConversationReaderPlace()
        park(place, height: 45_000, offset: 30_000, distance: 1_000)
        place.jumpToMessageBegan()
        let restingSpan = span(height: 49_000, offset: 30_000, distance: 4_321)
        #expect(feed(place, [restingSpan]) == [.none])

        #expect(place.scrollCameToRest() == .message)
        #expect(place.isLandingOnMessage)
        #expect(!place.shouldReassertMessage)

        // The landing remains protected while the reader leaves the list untouched. Touching
        // it ends that protection and anchors the place to the last finite reading.
        place.readerTookHold()
        #expect(!place.isLandingOnMessage)
        #expect(place.anchoredDistance == 4_321)
        place.contentDidChange()
        #expect(feed(place, [span(height: 50_000, offset: 30_000, distance: 5_321)]) == [.offset(31_000)])
    }

    @Test("a reader taking hold cancels a message landing")
    func aReaderTakingHoldCancelsMessageLanding() {
        let place = ConversationReaderPlace()
        place.jumpToMessageBegan()
        place.readerTookHold()

        #expect(!place.isLandingOnMessage)
        #expect(!place.shouldReassertMessage)
        #expect(place.scrollCameToRest() == .none)
    }
}
