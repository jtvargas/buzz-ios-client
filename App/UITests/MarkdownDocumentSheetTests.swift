import XCTest

/// The document sheet, reached the way a reader reaches it: a real message row, a real link
/// press, a real fetch.
///
/// # Why a UI test and not a unit test
///
/// Both of the things it checks only exist once the sheet is on a screen with a finger on it.
/// Text selection is a system gesture — `.textSelection(.enabled)` is an environment value with
/// no observable effect until a long press engages it, and the only proof it engaged is the
/// edit menu appearing. And the share button is a `ShareLink`, which has nothing to assert
/// about below the toolbar it draws.
///
/// This one shape reaches the network, unlike the rest of the suite: the sheet's job is to
/// fetch a file, and stubbing the fetch would leave exactly the path under test unrun.
final class MarkdownDocumentSheetTests: XCTestCase {
    /// Long-pressing the document's prose puts the system's Copy menu up.
    func testLongPressSelectsDocumentText() {
        let app = openDocument()

        let paragraph = longestParagraph(in: app)
        XCTAssertNotNil(paragraph, "the document rendered no paragraph to press")
        guard let paragraph else { return }

        // Near the start of the first line: the file's prose is dense with links, and a long
        // press that lands on a link run is the link's gesture, not a selection.
        paragraph.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.2))
            .press(forDuration: 1.0)

        XCTAssertTrue(
            app.menuItems["Copy"].waitForExistence(timeout: 3),
            "a long press on document text did not begin a selection — "
                + "menu items on screen: \(app.menuItems.allElementsBoundByIndex.map { $0.label })"
        )
    }

    /// The share button is on the sheet and opens the system share sheet.
    func testShareButtonPresentsTheShareSheet() {
        let app = openDocument()

        let share = app.buttons["markdown-share"]
        XCTAssertTrue(share.waitForExistence(timeout: 5), "the sheet has no share button")
        share.tap()

        // The activity view is the system's, so the stable thing to wait on is one of the
        // actions it always offers for a file rather than the sheet's own container.
        let copy = app.buttons["Copy"]
        let airDrop = app.buttons["AirDrop"]
        let appeared = copy.waitForExistence(timeout: 6) || airDrop.exists
        XCTAssertTrue(appeared, "the share sheet did not present")
    }

    // MARK: - Reaching the sheet

    /// Launches the fixture, presses the link, and returns once the document has rendered.
    private func openDocument() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureConversation", "thread", "-markdownDocument"]
        app.launch()

        let link = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "TEST.md")
        ).firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 15), "the fixture message never rendered")
        link.tap()

        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 10),
            "the document sheet never presented"
        )
        // The fetch is real, so the wait is for the document's own words rather than for a
        // spinner to go: this file opens on a title the parser draws as a heading.
        let body = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", "Lorem ipsum")
        ).firstMatch
        XCTAssertTrue(body.waitForExistence(timeout: 30), "the document never finished loading")
        return app
    }

    /// The tallest static text on screen, which in a rendered document is a wrapped paragraph
    /// rather than a heading or a list marker — the safest place to put a press.
    private func longestParagraph(in app: XCUIApplication) -> XCUIElement? {
        app.staticTexts.allElementsBoundByIndex
            .filter { $0.exists && $0.frame.height > 40 && $0.label.count > 120 }
            .max { $0.frame.height < $1.frame.height }
    }
}

extension MarkdownDocumentSheetTests {
    /// Copy all is reachable and confirms itself.
    ///
    /// The pasteboard is not asserted from the runner: `UIPasteboard.general` in a UI test
    /// process is not the app's, so reading it back would assert about the wrong pasteboard.
    /// What is observable — and what the reader is actually promised — is the button turning
    /// into a checkmark, which only happens after the copy.
    func testCopyAllConfirms() {
        let app = openDocument()

        let copy = app.buttons["markdown-copy-all"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "the sheet has no Copy all button")
        XCTAssertTrue(copy.isEnabled, "Copy all stayed disabled after the document loaded")
        copy.tap()

        XCTAssertTrue(
            app.images["checkmark"].waitForExistence(timeout: 2),
            "Copy all did not confirm"
        )
    }
}
