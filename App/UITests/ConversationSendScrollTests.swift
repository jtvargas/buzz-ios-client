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

    // MARK: - Driving it

    /// Drags the conversation back into history and lets it settle.
    private func park(_ app: XCUIApplication) {
        for _ in 0 ..< 2 {
            app.windows.firstMatch.swipeDown(velocity: .slow)
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
