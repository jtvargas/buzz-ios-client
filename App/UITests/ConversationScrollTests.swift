import XCTest

/// The conversation shapes that have caught every scroll defect this app has shipped.
///
/// # Why this suite exists
///
/// Three defects went out in a row — `#49`, `#50`, `#52` — and the owner found all three on a
/// device. Nothing in CI could have caught any of them. What did catch them was driving a
/// conversation of a particular *shape* — how many messages, how tall the tallest, where it
/// sits — through a real keyboard, and then asking a question no geometry read can answer:
/// **is there a message on the screen?**
///
/// That is what these assert. `ConversationFixture` supplies the shapes; the app under test is
/// the shipping `ThreadView` and `ChannelTimelineView`, reached through the initialisers that
/// name their collaborators instead of taking a `SyncEngine`.
///
/// The shapes themselves, and how a row's place is read off the display, live in
/// ``ConversationScrollHarness``, which is where a second suite driving the same shapes through
/// something other than a rising keyboard would take them from.
final class ConversationScrollTests: ConversationScrollHarness {
    /// The owner's report, exactly: open a conversation, touch nothing, tap the composer.
    ///
    /// Four assertions per shape, one per way this has actually failed:
    ///
    /// 1. **A message is readable** — before the tap, after it, and still five seconds later.
    ///    The blank conversation was a dead end, not a flash.
    /// 2. **The newest message's bottom edge clears the keyboard.** Not "is it readable" — see
    ///    below for why that question could not fail.
    /// 3. **It moved by the keyboard's own inset, neither less nor more.** Both directions,
    ///    also for the reason below.
    ///
    /// # Why assertions 2 and 3 are written the way they are
    ///
    /// Because the two they replace were structurally incapable of failing on the defect this
    /// test exists for, and did not fail on it for four pull requests.
    ///
    /// They were `readable(app).contains(newest)` and `abs(moved) <= allowance + 8`.
    /// ``readable(_:)`` scores a row that *intersects* the band, and the shapes that matter here
    /// rest on a message taller than the screen — so a newest message with its last 311 points
    /// buried under the keyboard still counted as readable. And a one-sided bound admits zero:
    /// a conversation that did not move at all passed as "moved no further than the keyboard".
    ///
    /// The owner reported exactly that — *"the message list does not push up, the composer and
    /// keyboard end up covering the latest message"* — while this test was green. Recovered from
    /// its own logs afterwards: `thread-8-longlast` moved `m7 -1933 → -2244` against a 311-point
    /// keyboard, and `thread-8-longlast-primed`, the same content delivered one relay round trip
    /// later, moved `m7 -1933 → -1933`.
    ///
    /// So both are now stated as the thing the owner can see: the last message sits above the
    /// composer, and it got there by following the keyboard.
    func testComposerFocusFromOpeningPosition() throws {
        for shape in Self.shapes {
            let app = launch(shape.arguments)
            defer { app.terminate() }

            let before = readable(app)
            print("SHAPE \(shape.name) before \(describe(app))")
            XCTAssertFalse(before.isEmpty, "\(shape.name): opened with no message readable")
            guard let newestBefore = rendered(app).last else {
                XCTFail("\(shape.name): nothing rendered")
                continue
            }

            let allowance = focusComposer(app)
            print("SHAPE \(shape.name) after  \(describe(app)) allowance=\(Int(allowance))")

            XCTAssertFalse(
                readable(app).isEmpty,
                "\(shape.name): BLANK — no message readable after focusing the composer"
            )
            guard let newestAfter = rendered(app).first(where: { $0.index == newestBefore.index }) else {
                XCTFail("\(shape.name): the newest message stopped being rendered when the keyboard arrived")
                continue
            }
            let band = readableBand(app)
            XCTAssertLessThanOrEqual(
                newestAfter.frame.maxY, band.maxY + 8,
                """
                \(shape.name): the last \(Int(newestAfter.frame.maxY - band.maxY))pt of the newest \
                message is under the composer and keyboard
                """
            )
            let moved = newestBefore.frame.minY - newestAfter.frame.minY
            XCTAssertEqual(
                moved, allowance, accuracy: 8,
                """
                \(shape.name): the newest message moved \(Int(moved))pt \
                where the keyboard took \(Int(allowance))pt
                """
            )

            Thread.sleep(forTimeInterval: 5)
            XCTAssertFalse(
                readable(app).isEmpty,
                "\(shape.name): still blank five seconds later — a dead end, not a flash"
            )
        }
    }

    /// The owner's own control, and the case `#52` left open: scroll up into history first, then
    /// tap the composer.
    ///
    /// Asserted as a bound rather than an equality, because two outcomes are both correct — the
    /// content slides up by the keyboard's inset, or it stays put and the keyboard covers the
    /// lower part of the screen. Moving *further* than the keyboard is the defect.
    func testComposerFocusAfterScrollingUp() throws {
        for shape in Self.shapes {
            let app = launch(shape.arguments)
            defer { app.terminate() }

            app.windows.firstMatch.swipeDown(velocity: .slow)
            Thread.sleep(forTimeInterval: 1.5)
            let parked = rendered(app)
            print("SHAPE \(shape.name) parked \(describe(app))")
            guard let anchor = readable(app).first else {
                XCTFail("\(shape.name): nothing readable after scrolling up")
                continue
            }

            let allowance = focusComposer(app)
            print("SHAPE \(shape.name) focused \(describe(app))")

            XCTAssertFalse(
                readable(app).isEmpty,
                "\(shape.name): BLANK after focusing the composer from a scrolled-up position"
            )
            if let before = parked.first(where: { $0.index == anchor.index }),
               let after = rendered(app).first(where: { $0.index == anchor.index }) {
                let moved = before.frame.minY - after.frame.minY
                XCTAssertLessThanOrEqual(
                    abs(moved), allowance + 8,
                    """
                    \(shape.name): a reader in history was moved \(Int(moved))pt \
                    where the keyboard took \(Int(allowance))pt
                    """
                )
            }
        }
    }
}
