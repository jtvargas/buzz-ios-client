import XCTest

/// Opening a picture of every shape, and what the screen looks like when it is open.
///
/// # Why this is a UI test and not a unit test
///
/// ``MessageMediaZoomFitTests`` already gates the fit *arithmetic* — a picture of any
/// shape lands inside the viewport it was given, and keeps its aspect ratio across the
/// swap from the inline bitmap to the full decode. What it cannot say is what that
/// viewport *is*: it takes the size as an argument, so it would go on passing if the
/// viewer handed a picture the room left over after a bar. That is precisely the thing
/// the owner rejected on sight, so it is the thing that has to be asserted against a real
/// screen.
///
/// So the assertions here are about *rectangles on the phone*: the picture layer is the
/// whole window, and the header pill is inside the safe area. Neither is arithmetic.
///
/// # And it is where the screenshots come from
///
/// Nothing else in this project draws a photograph. Every picture the sampler hangs off
/// the fixture is attached to the result bundle as it is opened, which is how a change to
/// this screen is reviewed by someone who is not holding the phone — the fit, the glass
/// over a near-white field, the paging chrome on a gallery. `xcresulttool export
/// attachments` takes them back out.
final class MediaViewerLayoutTests: XCTestCase {
    /// Each shape the fixture can hang off a conversation, and the alt text of the
    /// picture that is tapped to open it.
    ///
    /// `Pair` is two pictures in one message, so the tap goes through a mosaic cell and
    /// the viewer opens as a *gallery*. It appears twice on purpose: opening it on its
    /// **second** cell is the only thing that says a gallery lands on the picture that was
    /// tapped rather than on the first one in the message.
    static let shapes = [
        (shape: "Tall", alt: "Tall picture"),
        (shape: "Wide", alt: "Wide picture"),
        (shape: "Square", alt: "Square picture"),
        (shape: "Panorama", alt: "Panorama picture"),
        (shape: "Column", alt: "Column picture"),
        (shape: "Light", alt: "Light picture"),
        (shape: "Small", alt: "Small picture"),
        (shape: "Pair", alt: "Pair one"),
        (shape: "Pair", alt: "Pair two"),
    ]

    /// The identifiers the viewer puts on the two things measured here, repeated rather
    /// than imported: a UI-testing bundle drives the app from *outside* its process and
    /// links none of it, so `MessageMediaViewer.pictureIdentifier` is not a symbol here.
    /// These two strings are the whole contract between the halves.
    private enum Identifier {
        static let picture = "mediaViewerPicture"
        static let header = "mediaViewerHeader"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testEveryShapeOpensWholeUnderFloatingChrome() {
        for (offset, shape) in Self.shapes.enumerated() {
            let app = XCUIApplication()
            // One shape per launch, so the picture is the newest message and the
            // conversation never has to be scrolled to reach it. See
            // `ConversationFixture.Options.imageShape` for what scrolling cost.
            app.launchArguments = [
                "-fixtureConversation", "channel", "-messages=2", "-imageShape=\(shape.shape)",
            ]
            app.launch()
            defer { app.terminate() }
            XCTAssertFalse(
                app.otherElements["fixtureFailure"].exists,
                "\(shape.alt): the fixture could not build its conversation"
            )

            let inline = app.buttons[shape.alt]
            XCTAssertTrue(
                inline.waitForExistence(timeout: 20),
                "\(shape.alt): never rendered in the conversation"
            )
            XCTAssertTrue(inline.isHittable, "\(shape.alt): is not reachable in the conversation")
            if offset == 0 { attach(XCUIScreen.main.screenshot(), named: "00-conversation") }
            inline.tap()

            let close = app.buttons["Done"]
            let opened = close.waitForExistence(timeout: 10)
            // Before the assertions, so a failure leaves behind the picture of what failed.
            attach(XCUIScreen.main.screenshot(), named: String(format: "%02d-%@", offset + 1, shape.alt))
            XCTAssertTrue(opened, "\(shape.alt): the viewer did not open")
            // By the picture's own alt text, not by the viewer's identifier: a gallery
            // holds more than one page, and "some page is on screen" would pass while the
            // wrong one is. The inline picture in the conversation carries the same label
            // but is a Button, so this is unambiguous.
            let picture = app.images[shape.alt]
            XCTAssertTrue(picture.waitForExistence(timeout: 10), "\(shape.alt): the viewer did not open on it")
            XCTAssertEqual(
                picture.identifier, Identifier.picture,
                "\(shape.alt): what is on screen is not the viewer's own picture"
            )
            assertOwnersDrawing(app: app, picture: picture, close: close, named: shape.alt)
            if shape.alt == "Pair one" { swipeToTheNextPage(in: app, named: "Pair two") }

            close.tap()
            XCTAssertTrue(
                inline.waitForExistence(timeout: 10),
                "\(shape.alt): the viewer did not return to the conversation"
            )
        }
    }

    /// Swipes a gallery on by one and waits for it to come to rest.
    ///
    /// The property being asserted is the one a paging scroll view has and a loose,
    /// free-scrolling one does not: it settles **exactly** on a page, never between two.
    /// That is the mechanical half of the owner's report that swiping felt slippy, and it
    /// is the half a test can hold — the rest of it is his eye on a device.
    private func swipeToTheNextPage(in app: XCUIApplication, named alt: String) {
        app.swipeLeft()
        let next = app.images[alt]
        XCTAssertTrue(next.waitForExistence(timeout: 5), "\(alt): swiping did not reach it")
        let window = app.frame
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, abs(next.frame.minX - window.minX) > 1 {
            Thread.sleep(forTimeInterval: 0.2)
        }
        XCTAssertEqual(
            next.frame.minX, window.minX, accuracy: 1,
            "\(alt): the gallery came to rest \(Int(next.frame.minX - window.minX))pt off a page"
        )
    }

    /// The owner's drawing, as rectangles: `image content behind`, with the pill and the
    /// close button over it — and everything readable clear of the corners the system owns.
    private func assertOwnersDrawing(
        app: XCUIApplication,
        picture: XCUIElement,
        close: XCUIElement,
        named alt: String
    ) {
        let window = app.frame
        // FIRST, because it is the one an existence check cannot make. A gallery holds its
        // other pages in the same scroll view, at the same size, one screen to the side —
        // so "the tapped picture exists and is the size of the window" was true of a page
        // sitting off screen while the reader looked at a different one. Where it *is* is
        // the whole claim.
        XCTAssertEqual(
            picture.frame.minX, window.minX, accuracy: 1,
            "\(alt): is \(Int(picture.frame.minX - window.minX))pt off to the side — the viewer opened on another page"
        )
        let short = Int(window.height - picture.frame.height)
        XCTAssertEqual(
            picture.frame.height, window.height, accuracy: 1,
            "\(alt): the picture layer is \(short)pt short of the screen"
        )
        let narrow = Int(window.width - picture.frame.width)
        XCTAssertEqual(
            picture.frame.width, window.width, accuracy: 1,
            "\(alt): the picture layer is \(narrow)pt narrower than the screen"
        )

        // A pill at the very top of the window would be behind the clock and the Dynamic
        // Island, which is the half of the arrangement the picture layer does not answer for.
        let pill = app.descendants(matching: .any).matching(identifier: Identifier.header).firstMatch
        XCTAssertTrue(pill.exists, "\(alt): the header pill is missing")
        XCTAssertGreaterThan(
            pill.frame.minY, window.minY + 20,
            "\(alt): the header pill is against the top of the screen, under the status bar"
        )
        XCTAssertTrue(close.isHittable, "\(alt): the close button cannot be tapped")
        XCTAssertLessThan(
            pill.frame.maxX, close.frame.minX,
            "\(alt): the header pill has run into the close button"
        )
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        // Without this an attachment is dropped from the bundle on a passing test, which
        // is the run they are wanted from.
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
