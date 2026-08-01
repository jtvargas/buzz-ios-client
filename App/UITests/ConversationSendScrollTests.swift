import XCTest

/// Where the conversation puts an author who sends something from up in history.
///
/// # Why this is not part of the keyboard suite
///
/// ``ConversationScrollTests`` asks what a *rising keyboard* does to a reader's place, and
/// answers it without ever pressing send — the fixture's sender used to refuse. This asks the
/// other half of the same question, and it is the half the owner reported: scroll up, write
/// something, and the message you just wrote has to be on screen when you look up.
///
/// It cannot be asked of a sink that pretends. The whole behaviour under test lives in the
/// gap between the tap and the row: the message is not signed at the tap, so the jump the tap
/// asks for can only aim at whatever was newest *then*, and the row it is really about lands
/// through the store's own observation a beat later. So the fixture queues into its own store
/// now (`ConversationFixture.StoringSender`) and the message arrives the way any message does.
///
/// # Every assertion is a row frame
///
/// ``ConversationScrollHarness``' rule, for its reason: a `LazyVStack`'s own numbers are
/// estimates, and an assertion built on them passes while the screen is blank.
final class ConversationSendScrollTests: ConversationScrollHarness {
    /// What the test types. It is shaped like a fixture message on purpose — the harness reads
    /// rows by matching `Message <number>`, so the message the composer sends is found by the
    /// same reader as the ones the fixture seeded, with no test-only marker on the shipping row.
    private static let sentIndex = 999
    private static var sentText: String { "Message \(sentIndex) from the composer" }

    /// Two shapes, chosen for two properties this test needs and one it cannot have.
    ///
    /// Needs history to park in: `channel-50-plain` has fifty messages, and
    /// `thread-8-longopener` puts its sixty-line message at the *top*, which is what gives a
    /// short thread a screen or two above the reader.
    ///
    /// Cannot have a tall *newest* message: the non-vacuity check below asks that the newest
    /// row leave the readable band when the reader scrolls up, and a row taller than the
    /// viewport can be both well off the bottom and still intersecting it. What a tall newest
    /// message does to a rising keyboard is ``ConversationScrollTests``' subject.
    private static let sendShapes = ["channel-50-plain", "thread-8-longopener"]

    private static var shapesUnderTest: [Shape] {
        shapes.filter { sendShapes.contains($0.name) }
    }

    /// Scroll up into history, write a message, send it.
    ///
    /// Three assertions per shape:
    ///
    /// 1. **The swipe really parked the reader.** Without this the test compares a conversation
    ///    resting at its bottom to itself and passes on a surface that does nothing — the
    ///    failure mode that made 32 green keyboard readings meaningless on 2026-07-27.
    /// 2. **The message that was sent is readable.** Not "the conversation moved": moving and
    ///    landing somewhere else is exactly the defect, since the jump fires before the row
    ///    exists and the reader's place is then corrected back toward where they were.
    /// 3. **Its bottom edge clears the composer and the keyboard.** The keyboard stays up after
    ///    a send by design, so a message "readable" with its last lines under the keys is the
    ///    same half-answer assertion 2 of the keyboard suite exists to refuse.
    func testSendingFromHistoryLandsOnTheMessageJustSent() {
        for shape in Self.shapesUnderTest {
            let app = launch(shape.arguments)
            defer { app.terminate() }

            let atRest = rendered(app)
            park(app)
            let parked = rendered(app)
            print("SHAPE \(shape.name) parked \(describe(app))")
            XCTAssertTrue(
                movement(from: atRest, to: parked) > 100,
                "\(shape.name): the swipe did not park the reader in history — nothing is being tested"
            )
            XCTAssertNil(
                readable(app).first { $0.index == atRest.last?.index },
                "\(shape.name): the newest message is still readable, so the reader is not parked"
            )

            send(Self.sentText, in: app, shape: shape.name)
            print("SHAPE \(shape.name) sent   \(describe(app))")

            guard let landed = readable(app).first(where: { $0.index == Self.sentIndex }) else {
                let all = rendered(app).map { "m\($0.index)@\(Int($0.frame.minY))" }.joined(separator: " ")
                XCTFail("\(shape.name): the message that was just sent is not on screen; rendered=[\(all)]")
                continue
            }
            let band = readableBand(app)
            XCTAssertLessThanOrEqual(
                landed.frame.maxY, band.maxY + 8,
                """
                \(shape.name): the last \(Int(landed.frame.maxY - band.maxY))pt of the message \
                that was just sent is under the composer and keyboard
                """
            )
        }
    }

    /// The same trip from *deep* in history, which is the owner's report of 2026-07-31:
    /// *"sending a new message while deeply scrolled up … lands on empty space, forcing the
    /// user to manually scroll further."*
    ///
    /// # Why depth is its own case and not a bigger number in the one above
    ///
    /// Because it is a different mechanism, and the shallow case does not reach it. Two swipes
    /// leave the reader inside the band the surface still calls "away from the bottom" for one
    /// or two readings; from twenty messages back the jump spends most of a second in flight,
    /// and every geometry reading it produces on the way says `awayFromBottom`. The owner's
    /// tail freeze is written from exactly those readings — so it re-armed one frame after the
    /// send released it, and the author's own message, arriving newer than a boundary that had
    /// just been put back, was held behind it: never rendered, never landed on, counted into
    /// the pill instead. The trip then ended on whatever was newest before they typed.
    ///
    /// So the assertion that matters here is the same one as above — *the message I just sent
    /// is on screen, above the composer* — asked from a depth where the flight is long enough
    /// to be mistaken for the reader leaving.
    ///
    /// Channel only. The thread shapes hold eight replies, which is not two screens of history
    /// on this device however hard it is swiped, and a park that cannot go deep would assert
    /// the shallow case again under a different name.
    func testSendingFromDeepHistoryLandsOnTheMessageJustSent() {
        let shape = Self.shapesUnderTest.first { $0.name == "channel-50-plain" }
        guard let shape else { return XCTFail("channel-50-plain is not among the shapes") }
        let app = launch(shape.arguments)
        defer { app.terminate() }

        let newestAtRest = rendered(app).last?.index ?? 0
        parkDeep(app)
        print("SHAPE \(shape.name)-deep parked \(describe(app))")

        // Non-vacuity, and it is the whole point of this case: a park that did not go deep
        // asserts the shallow trip a second time. Measured in *messages* rather than points,
        // because that is what "deeply scrolled up" means to a reader.
        let newestParked = readable(app).last?.index ?? 0
        XCTAssertGreaterThanOrEqual(
            newestAtRest - newestParked,
            Self.deepEnough,
            "the reader is only \(newestAtRest - newestParked) messages back — this is not the deep case"
        )

        send(Self.sentText, in: app, shape: "\(shape.name)-deep")
        print("SHAPE \(shape.name)-deep sent   \(describe(app))")

        let band = readableBand(app)
        guard let landed = readable(app).first(where: { $0.index == Self.sentIndex }) else {
            let all = rendered(app).map { "m\($0.index)@\(Int($0.frame.minY))" }.joined(separator: " ")
            return XCTFail(
                "\(shape.name)-deep: the message that was just sent is not on screen; rendered=[\(all)]"
            )
        }
        XCTAssertLessThanOrEqual(
            landed.frame.maxY, band.maxY + 8,
            "\(shape.name)-deep: the message just sent is \(Int(landed.frame.maxY - band.maxY))pt under the composer"
        )
        // The other edge, and the one the report names. Landing *short* of the newest row
        // leaves it sitting a screen above the composer with nothing under it, which is the
        // "empty space" the reader then has to scroll out of themselves.
        XCTAssertGreaterThanOrEqual(
            landed.frame.maxY, band.maxY - Self.restsAgainstComposer,
            """
            \(shape.name)-deep: the message just sent rests \(Int(band.maxY - landed.frame.maxY))pt \
            above the composer, with empty space below it
            """
        )
    }

    // MARK: - Driving it

    /// How many messages back counts as *deep*. Two swipes on this shape move about eight, so
    /// this is comfortably past what the case above already covers.
    private static let deepEnough = 14

    /// How far above the composer the newest message may rest and still be said to be against
    /// it. Generous — the list carries 8pt of its own padding and a row's trailing metadata is
    /// not part of its text frame — but far short of the screenful the report describes.
    private static let restsAgainstComposer: CGFloat = 140

    /// Drags the conversation back into history and lets it settle.
    private func park(_ app: XCUIApplication) {
        for _ in 0 ..< 2 {
            app.windows.firstMatch.swipeDown(velocity: .slow)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// The same, until the conversation stops going back — several viewports rather than two.
    ///
    /// Fast, and many. A single row in a `-spread` channel is up to 833 points tall, so a slow
    /// swipe can cross less than one message; measured, eight of them moved the reader three.
    /// A flick carries its momentum and crosses several.
    ///
    /// Bounded by a count *and* by the history running out: this fixture paginates nothing, so
    /// once the oldest rendered row stops receding there is nothing above left to reach.
    private func parkDeep(_ app: XCUIApplication) {
        var oldest = rendered(app).map(\.index).min() ?? Int.max
        var stalls = 0
        for _ in 0 ..< 24 {
            app.windows.firstMatch.swipeDown(velocity: .fast)
            Thread.sleep(forTimeInterval: 0.3)
            let reached = rendered(app).map(\.index).min() ?? oldest
            stalls = reached < oldest ? 0 : stalls + 1
            if stalls >= 3 { break }
            oldest = min(oldest, reached)
        }
        Thread.sleep(forTimeInterval: 1.5)
    }

    /// How far the rows present in both readings travelled. Taken from a row rather than from
    /// the scroll view, for the harness' reason — and unsigned, because what it is asked is
    /// whether the conversation moved at all, not which way.
    private func movement(from before: [Row], to after: [Row]) -> CGFloat {
        let common = after.compactMap { row -> CGFloat? in
            guard let was = before.first(where: { $0.index == row.index }) else { return nil }
            return abs(row.frame.minY - was.frame.minY)
        }
        return common.max() ?? 0
    }

    /// Spins until `condition` holds, or gives up. Both waits below are on a *fact about the
    /// screen* rather than on a fixed sleep, so a slow machine costs seconds instead of a
    /// spurious red.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return condition()
    }

    /// Types into the real composer and presses the real send button, then waits for the row.
    ///
    /// Every step is checked, because this suite's one real risk is asserting a scroll outcome
    /// against a conversation nobody sent anything to: a `typeText` into a field that never got
    /// the keyboard types nothing, and a send button pressed on an empty draft is disabled and
    /// does nothing. Either way the shape below would read as "the surface did not scroll".
    private func send(_ text: String, in app: XCUIApplication, shape: String) {
        focusComposer(app)
        let field = app.textViews.firstMatch
        field.typeText(text)
        // Non-vacuity, both halves. A `typeText` into a field that did not have the keyboard
        // types nothing, and a send button pressed with an empty draft is disabled and does
        // nothing — either way the test would go on to assert against a conversation nobody
        // sent anything to.
        XCTAssertEqual(field.value as? String, text, "\(shape): the composer did not take the text")
        // Both labels, because the two surfaces name the same control differently — a channel
        // sends, a thread replies — and this suite drives one of each.
        let send = app.buttons["Send"].exists ? app.buttons["Send"] : app.buttons["Send reply"]
        XCTAssertTrue(send.waitForExistence(timeout: 5), "\(shape): no send button on screen")
        XCTAssertTrue(send.isEnabled, "\(shape): send is disabled with a draft in the composer")
        send.tap()

        // The draft clearing is the surface's own report that the send ran at all — a tap that
        // missed, or a `send()` that returned early, leaves the text where it was.
        XCTAssertTrue(
            waitFor(timeout: 3) { (field.value as? String)?.isEmpty ?? true },
            "\(shape): the composer still holds the draft, so the send never ran"
        )
        XCTAssertTrue(
            waitFor(timeout: 10) { rendered(app).contains { $0.index == Self.sentIndex } },
            "\(shape): the message was never rendered at all — this is not a scroll failure"
        )
        // The jump is animated, and reading frames mid-flight measures the trip rather than
        // where it ended.
        Thread.sleep(forTimeInterval: 1.5)
    }
}
