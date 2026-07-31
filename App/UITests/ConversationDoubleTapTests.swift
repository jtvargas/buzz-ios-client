import XCTest

/// Two quick taps on a message, and what they must not do to one.
///
/// # Why this cannot be a unit test
///
/// ``MessageTapArbiterTests`` holds the rule — one tap runs its action, two run the sheet —
/// and it would go on passing through the defect this file exists for. That defect is about
/// *who counts the finger*: a picture inside a message is a `Button` with an action of its
/// own, and the row's tap gesture fires for the same touch. If both of them reached the
/// arbiter, one tap on a picture would be counted twice and read as a double tap, and every
/// picture in the app would open the actions sheet instead of opening.
///
/// So what is asserted here is the wiring, from outside the process, on the two surfaces the
/// owner named: a message, and the picture inside it.
final class ConversationDoubleTapTests: ConversationScrollHarness {
    /// The one control the actions sheet always draws, whatever the message is and whoever
    /// sent it. The quick reactions above it are hidden on a read-only conversation, so they
    /// are the wrong thing to wait on.
    private static let sheetControl = "Copy Message"

    /// The viewer's close button — its *absence* is half of the owner's second requirement:
    /// double-tapping a picture must reach a sheet and must not open the picture.
    private static let viewerControl = "Done"

    /// The picture's own sheet, which is what a double tap on a picture opens — not the
    /// message's. See ``MediaActionsSheet`` for why those are two different sheets.
    private static let mediaSheetControl = "Save Image"

    /// A picture the fixture can hang off a message, by the alt text its inline button
    /// carries. One shape is enough here: this suite is about the gesture, not the fit —
    /// `MediaViewerLayoutTests` carries every shape.
    private static let picture = "Square picture"

    private static let imageConversation = [
        "-fixtureConversation", "channel", "-messages=2", "-imageShape=Square",
    ]

    // MARK: - A message

    func testDoubleTappingAMessageOpensItsActions() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=40"])

        let target = try XCTUnwrap(readable(app).dropLast().last, "no message row to tap")
        doubleTap(app, atY: target.frame.midY)

        let sheet = app.buttons[Self.sheetControl]
        XCTAssertTrue(
            sheet.waitForExistence(timeout: 5),
            "two quick taps on message \(target.index) opened no actions sheet — \(describe(app))"
        )
        // And the single tap that each of them would have been on its own was cancelled, not
        // merely reordered: a thread pushed behind the sheet is the failure this arrangement
        // exists to prevent, and it is visible here because the thread holds one message where
        // the channel holds forty.
        XCTAssertGreaterThan(
            rendered(app).count, 1,
            "the sheet opened over a pushed thread — the first tap's action ran as well"
        )
    }

    // MARK: - A picture inside it

    func testDoubleTappingAPictureOpensItsOwnActionsAndNotThePicture() {
        let app = launch(Self.imageConversation)

        let inline = picture(in: app)
        inline.doubleTap()

        XCTAssertTrue(
            app.buttons[Self.mediaSheetControl].waitForExistence(timeout: 5),
            "two quick taps on a picture opened no actions sheet"
        )
        // The owner's second message, in as many words: the double tap must not interfere with
        // opening the image. It is asserted after the sheet has arrived rather than
        // immediately, so this is "the viewer never opened", not "the viewer had not opened
        // yet".
        XCTAssertFalse(
            app.buttons[Self.viewerControl].exists,
            "the picture opened as well as its actions sheet"
        )
        // And it is the *picture's* sheet, not the message's. The two are opened by the same
        // gesture on overlapping targets, so which one arrived is the whole assertion.
        XCTAssertFalse(
            app.buttons[Self.sheetControl].exists,
            "a picture's double tap opened the message's actions instead of its own"
        )
    }

    /// The other half, and the one that would break silently: a single tap on a picture still
    /// opens it, a quarter of a second later than it used to.
    ///
    /// `MediaViewerLayoutTests` asserts this for every shape, and this is not a duplicate of
    /// it: that suite is about what the viewer *looks like* once open. This one is here so
    /// that a change to the arbitration is answered by the file that changed it.
    func testASingleTapOnAPictureStillOpensIt() {
        let app = launch(Self.imageConversation)

        picture(in: app).tap()

        XCTAssertTrue(
            app.buttons[Self.viewerControl].waitForExistence(timeout: 10),
            "one tap on a picture no longer opens it — the deferred tap was dropped"
        )
        XCTAssertFalse(
            app.buttons[Self.mediaSheetControl].exists,
            "one tap on a picture opened its actions sheet"
        )
    }

    // MARK: - Driving

    private func picture(in app: XCUIApplication) -> XCUIElement {
        let inline = app.buttons[Self.picture]
        XCTAssertTrue(inline.waitForExistence(timeout: 20), "the fixture's picture never rendered")
        XCTAssertTrue(inline.isHittable, "the fixture's picture is not reachable")
        return inline
    }

    /// Two taps at the middle of the row at `atY`.
    ///
    /// Through a coordinate rather than an element, exactly as `ConversationDragScrollTests`
    /// taps: the horizontal middle of a row is message text and nothing else, so the gesture
    /// cannot land on the avatar, a mention, or a reaction chip — each of which is a control
    /// with a claim of its own and would make this test about something other than the row.
    private func doubleTap(_ app: XCUIApplication, atY: CGFloat) {
        let window = app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: window.midX, dy: atY))
            .doubleTap()
    }
}
