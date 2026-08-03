import XCTest

/// Temporary: walks the two identity routes off the hero — create a new key, and paste an
/// existing one — and attaches a screenshot of each step, so the design can be looked at rather
/// than reasoned about. Not a gate — delete after review, with `JoinWizardShots`.
final class IdentityWalkShots: XCTestCase {
    func testWalksCreateNewIdentity() {
        let app = XCUIApplication()
        app.launch()

        let create = app.buttons["Create new identity"]
        XCTAssertTrue(create.waitForExistence(timeout: 20), "no Create new identity link")
        create.tap()

        let relay = relayField(in: app)
        XCTAssertTrue(relay.waitForExistence(timeout: 10), "no relay field on step one")
        shoot(app, "10-create-relay-empty")

        // Tapped by coordinate: the field's own frame is the text line inside a padded well, and
        // the well is what a finger lands on.
        relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        relay.typeText("wss://relay.example")
        dismissKeyboard(in: app)
        sleep(3)
        shoot(app, "11-create-relay-filled")

        tapNext(in: app)
        sleep(2)
        shoot(app, "12-create-profile")

        // The quick row is labelled by each glyph's unicode name.
        let bee = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bee'")).firstMatch
        if bee.waitForExistence(timeout: 5) {
            bee.tap()
            sleep(1)
        }

        tapNext(in: app)
        sleep(2)
        shoot(app, "13-create-key")
    }

    func testWalksPasteExistingKey() {
        let app = XCUIApplication()
        app.launch()

        let paste = app.buttons["Paste existing key"]
        XCTAssertTrue(paste.waitForExistence(timeout: 20), "no Paste existing key link")
        paste.tap()

        let relay = relayField(in: app)
        XCTAssertTrue(relay.waitForExistence(timeout: 10), "no relay field on step one")
        relay.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        relay.typeText("wss://relay.example")
        dismissKeyboard(in: app)
        sleep(3)
        shoot(app, "20-paste-relay")

        tapNext(in: app)
        sleep(2)
        shoot(app, "21-paste-key")
    }

    // MARK: - Helpers

    /// Scoped by placeholder: the welcome screen's own relay field is still in the tree behind
    /// the pushed step, and it is the one `firstMatch` picks.
    private func relayField(in app: XCUIApplication) -> XCUIElement {
        app.textFields
            .matching(NSPredicate(format: "placeholderValue CONTAINS 'relay.example'"))
            .firstMatch
    }

    private func dismissKeyboard(in app: XCUIApplication) {
        let done = app.buttons["Done"].firstMatch
        if done.exists { done.tap() }
    }

    private func tapNext(in app: XCUIApplication) {
        let next = app.buttons["Next"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 10), "no Next button")
        next.tap()
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
