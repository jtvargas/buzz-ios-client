import CoreGraphics
@testable import Hive
import Testing

/// What a change in the content's height does to the reader's place.
///
/// Every case here is a sequence of geometry readings, because that is what the scroll
/// view produces and because the bug this replaces was in the *sequence*: correcting
/// against the reading before the current one made each correction the reference for the
/// next, and a `LazyVStack` re-measures several times per page load.
///
/// Deliberately not here: that `defaultScrollAnchor(.bottom, for: .sizeChanges)` fails to
/// do this at all. That is a fact about SwiftUI, not about this type, and it was settled
/// in a harness around the shipping ``ConversationScaffold``
/// (`~/.buzz/.scratch/scrollharness`) — the measurements are recorded on
/// ``ConversationReaderPlace``.
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

    // MARK: - Nothing to correct against

    @Test("the first reading corrects nothing")
    func firstReading() {
        let place = ConversationReaderPlace()
        #expect(place.correction(for: span(height: 5_000, offset: 4_000, distance: 0), atBottomSlack: slack) == .none)
    }

    @Test("a height of zero is 'not measured yet', not 'empty'")
    func unmeasuredContent() {
        // A scroll view mid-first-layout reports zero, and the height that follows it is
        // the first real one — not a change to correct for.
        let place = ConversationReaderPlace()
        let corrections = feed(place, [
            span(height: 0, offset: 0, distance: 0),
            span(height: 5_000, offset: 4_000, distance: 0),
        ])
        #expect(corrections == [.none, .none])
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

    // MARK: - A conversation nobody has moved

    @Test("content arriving after the first layout lands on the newest message")
    func lateFillGoesToTheBottom() {
        // The report: a thread primes with its opener alone, and the replies land a relay
        // round trip later against a height the stack had never measured.
        let place = ConversationReaderPlace()
        let corrections = feed(place, [
            span(height: 600, offset: -116, distance: -558),
            span(height: 12_240, offset: 66, distance: 11_300),
        ])
        #expect(corrections == [.none, .bottom])
    }

    @Test("a height that settles in instalments lands on the newest message every time")
    func settlingGoesToTheBottom() {
        let place = ConversationReaderPlace()
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
        let corrections = feed(place, [
            span(height: 5_000, offset: 4_000, distance: 0),
            // Still there — this is the reading the reference is taken from.
            span(height: 5_000, offset: 4_000, distance: 0),
            // A message arrives.
            span(height: 5_400, offset: 4_000, distance: 400),
        ])
        #expect(corrections == [.none, .none, .bottom])
    }

    // MARK: - A reader who has moved

    @Test("an older page arriving above a reader restores their distance from the newest")
    func olderPageRestoresDistance() {
        // The measured failure: 50 rows inserted above, the raw offset kept, the reader a
        // whole page backwards.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        let corrections = feed(place, [
            span(height: 45_882, offset: 44_300, distance: 1_000),
            span(height: 45_882, offset: 44_300, distance: 1_000),
            span(height: 80_338, offset: 44_300, distance: 35_456),
        ])
        // 44_300 + (35_456 - 1_000): the offset at which the distance to the newest
        // message is the one they had.
        #expect(corrections == [.none, .none, .offset(78_756)])
    }

    @Test("a settling run aims at one reference instead of chasing itself")
    func settlingDoesNotDrift() {
        // Three height changes for one page load, with no stable reading between them —
        // which is what a `LazyVStack` produces. Each correction must target the distance
        // the reader actually had, not the one the previous correction produced.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        _ = feed(place, [
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 40_000, offset: 30_000, distance: 1_000),
        ])
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
        let corrections = feed(place, [
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 40_000.3, offset: 30_000, distance: 1_000.3),
        ])
        #expect(corrections == [.none, .none, .none])
    }

    // MARK: - Who is allowed to move the list

    @Test("nothing is corrected while the reader is scrolling")
    func scrollingIsLeftAlone() {
        let place = ConversationReaderPlace()
        place.hasMoved = true
        place.isScrolling = true
        let corrections = feed(place, [
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 60_000, offset: 30_000, distance: 21_000),
        ])
        #expect(corrections == [.none, .none, .none])
    }

    @Test("a drag mid-settle still updates where the reader is")
    func draggingUpdatesTheReference() {
        // The reference is taken from readings where the height held still, and those
        // happen during a drag too — otherwise a reader who scrolled and then received a
        // page would be restored to where they were before the drag.
        let place = ConversationReaderPlace()
        place.hasMoved = true
        place.isScrolling = true
        _ = feed(place, [
            span(height: 40_000, offset: 30_000, distance: 1_000),
            span(height: 40_000, offset: 25_000, distance: 6_000),
        ])
        place.isScrolling = false
        let corrections = feed(place, [
            span(height: 60_000, offset: 25_000, distance: 26_000),
        ])
        #expect(corrections == [.offset(45_000)]) // 25_000 + (26_000 - 6_000)
    }
}
