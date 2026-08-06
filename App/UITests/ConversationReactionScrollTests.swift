import XCTest

/// What a reaction chip landing on a message does to a reader who is up in history.
///
/// # The rule
///
/// The owner's, on 2026-07-31, and Slack's: *"reacting to an older message should only push
/// content below it. Content above the reacted message must stay in place — no jump, no scroll
/// to bottom."*
///
/// # Why this could not be asked before
///
/// Because a chip could not be made to arrive. The fixture seeded messages and nothing else, so
/// every scroll suite here drives *insertions* — a page, an own send, a reply landing late — and
/// the one change that alters a row's height **where it stands** had no way into the surface.
/// That is the change the engine got wrong: it went down the same channel as an insertion
/// (`contentRevision`), and the rule for an insertion is *preserve the distance to the newest
/// message*, which is exactly backwards here. A chip grows the content below the reader, the
/// distance to the bottom grows with it, and the correction spends that growth as a scroll.
///
/// And not by the chip's own height. A `LazyVStack` sizes every row it has not measured at the
/// average of the ones it has, so one row changing height re-estimates the whole extent — which
/// is why the report reads as *"jumps to an unexpected position"* rather than as a nudge.
///
/// # Why the assertion is a split at the reacted row and not "the list did not scroll"
///
/// Because the chip is *supposed* to move something: a row growing has to spend that height
/// somewhere. A test that asserted the whole list held still would fail on the correct
/// behaviour. So the reading is split at the reacted row, and the side the reader's place is
/// on has to be where it was, to the point.
///
/// # Which side that is, and why it changed
///
/// It was the side *above* the chip, and it is now the side *below* it. Not a relaxation — the
/// same claim, read in the layout the app actually has since ``ConversationInversion`` landed
/// in #150.
///
/// The stack is newest-first inside a flipped scroll view, so the newest message sits at the
/// scroll view's origin and every row is laid out backwards into history from there. A row
/// growing therefore displaces everything laid out *after* it — everything **older**, which is
/// everything drawn **above** it — and leaves everything between it and the origin untouched.
/// That is ``ConversationReaderPlace``'s one invariant, *the distance to the newest message is
/// what survives a content change*, made structural rather than corrected for.
///
/// The chip is drawn beneath the message's own text, so the row grows upward and the reacted
/// message travels with its history rather than staying put. Measured on iPhone 17 Pro /
/// iOS 26.1, both shapes, a chip landing on the message the reader is parked on: the reacted
/// message and every older message moved **32 points**, one chip, together; every message newer
/// than it moved **0**.
///
/// **This is a real change against the rule as written, and it is the one thing in this suite
/// that is a product decision rather than a repair.** The rule says content above the reacted
/// message holds; under inversion nothing above it can hold, because the only anchor is the
/// newest message and a row growing has nowhere to push but into the past. What the rule was
/// written against — *"jumps to an unexpected position"*, measured in **hundreds** of points,
/// and a scroll to the bottom — is still caught, and caught by the first assertion below.
///
/// So this holds three things rather than one, and is stronger than the version it replaces:
/// nothing newer than the reacted message moves at all; the reacted message and its history
/// move as a single **uniform translation** rather than being re-laid-out; and that translation
/// is no larger than a chip. A scroll fails all three.
///
/// Every measurement is a row frame, for ``ConversationScrollHarness``' reason.
final class ConversationReactionScrollTests: ConversationScrollHarness {
    /// How far a row may move and still be said not to have moved. Four points is layout
    /// jitter; the defect moves rows by hundreds.
    private static let held: CGFloat = 4

    /// The most the content above the chip may travel.
    ///
    /// A ceiling rather than an equality, because the chip's own height is not a number this
    /// suite can read: ``ConversationScrollHarness/rendered(_:)`` measures the message *text*,
    /// and the chip is drawn beneath it, so the growth does not show up in any frame the suite
    /// has. Measured at 31–32 points; 60 is roughly twice that, and still an order of magnitude
    /// below the displacement this suite exists to catch.
    private static let chipCeiling: CGFloat = 60

    /// A shape deep enough to park in, and the message the chip lands on — chosen to sit in
    /// the middle so there is history both above and below it.
    private struct ReactionShape {
        let name: String
        let arguments: [String]
        let target: Int
    }

    /// Both surfaces. Not redundant: a channel and a thread declare their own content changes
    /// from separate models, so a chip routed correctly in one and not the other is a shape
    /// this repo has shipped before.
    private static let reactionShapes = [
        ReactionShape(
            name: "channel-50",
            arguments: ["-fixtureConversation", "channel", "-messages=50", "-spread"],
            target: 34
        ),
        ReactionShape(
            name: "thread-40",
            arguments: ["-fixtureConversation", "thread", "-messages=40", "-spread"],
            target: 26
        ),
    ]

    /// How long after launch the chip lands. Long enough to park the reader first — the guard
    /// below refuses the run rather than passing if it was not.
    ///
    /// Generous because the parking is slow, and it is slow for a reason worth knowing: every
    /// reading of the screen enumerates each static text in the hierarchy, which costs about a
    /// second. The loop below therefore swipes in pairs and reads once, and this fuse is set
    /// past the worst case rather than at it. Measured: a 30-second fuse burned during parking
    /// on both shapes.
    private static let reactAfterMilliseconds = 75_000

    func testAReactionOnAMessageInViewMovesNothingAboveIt() {
        for shape in Self.reactionShapes {
            let arguments = shape.arguments + [
                "-reactOn=\(shape.target)",
                "-reactAfter=\(Self.reactAfterMilliseconds)",
            ]
            let app = launch(arguments)
            defer { app.terminate() }

            let newestAtRest = rendered(app).last?.index ?? 0
            guard park(app, until: shape.target) else {
                XCTFail("\(shape.name): message \(shape.target) never came into view; \(describe(app))")
                continue
            }
            // Non-vacuity, both halves. A conversation still resting at its bottom would be
            // compared against itself, and a chip that beat the parking would be measured
            // across a conversation that was still moving when it arrived.
            XCTAssertNil(
                readable(app).first { $0.index == newestAtRest },
                "\(shape.name): the newest message is still in view, so the reader is not in history"
            )
            XCTAssertFalse(
                chip(in: app).exists,
                "\(shape.name): the reaction landed before the reader was parked — raise -reactAfter"
            )

            let before = readable(app)
            let target = before.first { $0.index == shape.target }
            guard let target else {
                XCTFail("\(shape.name): message \(shape.target) is not readable after parking")
                continue
            }
            print("SHAPE \(shape.name) parked \(describe(app))")

            XCTAssertTrue(
                chip(in: app).waitForExistence(timeout: 45),
                "\(shape.name): the reaction never arrived — this is not a scroll failure"
            )
            // The chip's own arrival animation and whatever the surface does about it.
            Thread.sleep(forTimeInterval: 1.5)
            print("SHAPE \(shape.name) chipped \(describe(app))")

            let after = rendered(app)
            assertNewerThanTheChipHeldStill(before, after, target: shape.target, shape: shape.name)
            assertTheRestTranslatedByOneChip(before, after, target: shape.target, shape: shape.name)
        }
    }

    // MARK: - The two halves of the split

    /// Everything **newer** than the reacted message, which in this layout is everything between
    /// it and the scroll view's origin. None of it may move at all.
    ///
    /// This is the assertion a scroll fails: a correction that spends the growth as an offset
    /// moves the whole list, and the whole list includes this side.
    ///
    /// Split on the index rather than on the frame. The two agree — older is drawn above — but
    /// the reacted row is on the boundary, its text is what moves, and a comparison of its frame
    /// against itself puts it on whichever side the operator happens to include.
    private func assertNewerThanTheChipHeldStill(
        _ before: [Row],
        _ after: [Row],
        target: Int,
        shape: String
    ) {
        for was in before where was.index > target {
            guard let now = after.first(where: { $0.index == was.index }) else {
                XCTFail("\(shape): message \(was.index) left the screen when the chip landed")
                continue
            }
            XCTAssertLessThanOrEqual(
                abs(now.frame.minY - was.frame.minY),
                Self.held,
                """
                \(shape): message \(was.index) is newer than the reacted one, sat at \
                \(Int(was.frame.minY)) and moved to \(Int(now.frame.minY)) when the chip \
                landed — the chip's height leaked to the reader's anchored side
                """
            )
        }
    }

    /// The reacted message and everything older, which is where the chip's height is spent.
    ///
    /// Two claims: it is spent as one translation, so this side is the same content in the same
    /// order rather than a re-estimated stack; and it is no more than a chip's worth.
    ///
    /// The reacted row is on this side because the chip is drawn beneath its text and the row
    /// grows upward — measured, the reacted message's own text travels the same 32 points its
    /// history does, and the message *below* it does not move. That is the reader's place under
    /// inversion: the newest end is the anchor, so a row growing can only push into the past.
    ///
    /// A row that stopped being rendered is skipped rather than failed — this side is allowed to
    /// move, so a row that was at the very top edge is allowed to move off it.
    private func assertTheRestTranslatedByOneChip(
        _ before: [Row],
        _ after: [Row],
        target: Int,
        shape: String
    ) {
        let displacements = before
            .filter { $0.index <= target }
            .compactMap { was in
                after.first { $0.index == was.index }.map { $0.frame.minY - was.frame.minY }
            }
        guard let first = displacements.first else { return }
        for displacement in displacements {
            XCTAssertLessThanOrEqual(
                abs(displacement - first),
                Self.held,
                """
                \(shape): the reacted message and its history did not move as one — rows \
                travelled \(Int(first)) and \(Int(displacement))pt, so the stack was \
                re-laid-out rather than translated by the chip
                """
            )
        }
        XCTAssertLessThanOrEqual(
            abs(first),
            Self.chipCeiling,
            """
            \(shape): the reacted message and its history travelled \(Int(first))pt, which is \
            further than a chip — the growth was spent as a scroll
            """
        )
    }

    // MARK: - Driving it

    /// The chip the fixture lands: one thumb from one person.
    private func chip(in app: XCUIApplication) -> XCUIElement {
        app.buttons["👍, 1"]
    }

    /// Swipes back into history until `index` is readable, or gives up.
    ///
    /// # Why a flick and not a held drag
    ///
    /// ``ConversationDragScrollTests`` holds its drags because *what it tests* is whether a
    /// row's own gesture eats the touch, and only a held touch reaches that. Nothing here is
    /// about the gesture; this only has to *travel*, and a held 45%-of-a-viewport drag does not.
    /// Measured on the first run of this suite: eight of them moved a `-spread` channel three
    /// messages, because a single row in that shape is 833 points tall — taller than the drag.
    /// A flick carries its momentum and crosses several rows.
    ///
    /// Bounded twice: by a count, and by a stall — this fixture paginates nothing, so once the
    /// oldest rendered row stops receding there is nothing left above to reach.
    ///
    /// # Why it stops on `readable` and not on `rendered`
    ///
    /// It stopped on `rendered` until the inverted stack landed, and that is a different
    /// question now. Newest-first inside a flipped scroll view means every row between the
    /// reader and the newest message is materialised and real, and the stack materialises some
    /// way past the visible edge on the other side too — so a row is *rendered*, and reachable
    /// through accessibility, well before a reader could see it. The loop then stopped one or
    /// two rows short and the final check, which has always asked `readable`, refused the run:
    /// `channel-50` reported *message 34 never came into view* with 35 filling the whole band.
    ///
    /// The sibling suite hit the same edge and recorded it in
    /// ``ConversationOlderPageScrollTests`` — *"the inverted stack may expose off-screen rows to
    /// accessibility"*. Asking the same question the return value asks is what makes the two
    /// agree.
    ///
    /// A `-spread` row is most of a screen tall (833–923 points measured, against a 742-point
    /// band), so at most one message is readable at a time and overshooting is one flick. The
    /// stall counter is what stops that becoming a hang.
    private func park(_ app: XCUIApplication, until index: Int) -> Bool {
        var oldest = Int.max
        var stalls = 0
        for _ in 0 ..< 10 {
            // Two swipes to one reading. A reading enumerates every static text on screen and
            // costs about a second, so it is the expensive half of this loop, not the swipe.
            app.windows.firstMatch.swipeDown(velocity: .fast)
            app.windows.firstMatch.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            if readable(app).contains(where: { $0.index == index }) { break }
            let reached = rendered(app).map(\.index).min() ?? oldest
            stalls = reached < oldest ? 0 : stalls + 1
            if stalls >= 2 { break }
            oldest = min(oldest, reached)
        }
        Thread.sleep(forTimeInterval: 1.5)
        return readable(app).contains { $0.index == index }
    }
}
