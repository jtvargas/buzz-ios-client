import XCTest

/// Temporary: walks the join wizard and attaches a screenshot of each step, so the design can be
/// looked at rather than reasoned about. Not a gate — delete after review.
final class JoinWizardShots: XCTestCase {
    func testWalksTheWizard() {
        let app = XCUIApplication()
        app.launch()

        shoot(app, "01-hero")

        let join = app.buttons["Join with an Invite"]
        XCTAssertTrue(join.waitForExistence(timeout: 20), "no Join with an Invite button")
        join.tap()

        // Scoped by placeholder: the welcome screen's own relay field is still in the tree
        // behind the sheet, and it is the one `firstMatch` picks.
        let field = app.textFields
            .matching(NSPredicate(format: "placeholderValue CONTAINS 'invite'")).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no invite field")
        shoot(app, "02-community-empty")

        // Tapped by coordinate: the field's own frame is the 20pt text line inside a padded
        // well, and the well is what a finger lands on.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        field.typeText("https://relay.example/invite/v2.abc")
        if app.buttons["Done"].firstMatch.exists { app.buttons["Done"].firstMatch.tap() }
        sleep(4)
        shoot(app, "03-community-filled")

        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10), "no Next button")
        next.tap()
        sleep(2)
        shoot(app, "04-profile-empty")

        // The quick row is labelled by each glyph's unicode name.
        let bee = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'bee'")).firstMatch
        if bee.waitForExistence(timeout: 5) {
            bee.tap()
            sleep(2)
            shoot(app, "05-profile-picked")
        }

        app.buttons["Next"].firstMatch.tap()
        sleep(2)
        shoot(app, "06-identity")
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
