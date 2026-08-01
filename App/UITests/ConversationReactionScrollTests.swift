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
/// # Why the assertion is "nothing above it moved" and not "the list did not scroll"
///
/// Because the chip is *supposed* to move something: everything below the row it lands on. A
/// test that asserted the whole list held still would fail on the correct behaviour. So the
/// reading is split at the reacted row, and only what sits above it — what the reader is
/// actually looking at — has to be where it was, to the point.
///
/// Every measurement is a row frame, for ``ConversationScrollHarness``' reason.
final class ConversationReactionScrollTests: ConversationScrollHarness {
    /// How far a row may move and still be said not to have moved. Four points is layout
    /// jitter; the defect moves rows by hundreds.
    private static let held: CGFloat = 4

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
            // Split at the reacted row: what is above it is the reader's place, what is below
            // it is allowed — required — to be pushed down by the chip.
            for was in before where was.frame.maxY <= target.frame.minY {
                guard let now = after.first(where: { $0.index == was.index }) else {
                    XCTFail("\(shape.name): message \(was.index) left the screen when the chip landed")
                    continue
                }
                XCTAssertLessThanOrEqual(
                    abs(now.frame.minY - was.frame.minY),
                    Self.held,
                    """
                    \(shape.name): message \(was.index) sat above the reacted one at \
                    \(Int(was.frame.minY)) and moved to \(Int(now.frame.minY)) when the chip \
                    landed — content above the reacted message did not stay in place
                    """
                )
            }
        }
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
    private func park(_ app: XCUIApplication, until index: Int) -> Bool {
        var oldest = Int.max
        var stalls = 0
        for _ in 0 ..< 10 {
            // Two swipes to one reading. A reading enumerates every static text on screen and
            // costs about a second, so it is the expensive half of this loop, not the swipe.
            app.windows.firstMatch.swipeDown(velocity: .fast)
            app.windows.firstMatch.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            let shown = rendered(app)
            if shown.contains(where: { $0.index == index }) { break }
            let reached = shown.map(\.index).min() ?? oldest
            stalls = reached < oldest ? 0 : stalls + 1
            if stalls >= 2 { break }
            oldest = min(oldest, reached)
        }
        Thread.sleep(forTimeInterval: 1.5)
        return readable(app).contains { $0.index == index }
    }
}
