import XCTest

/// Attaching a picture, on a real screen.
///
/// # Why this is a UI test
///
/// ``ComposerAttachmentsTests`` gates the *model* — the upload, the cap, the removal
/// racing an upload, the send gate — and it can say nothing at all about what any of
/// that looks like. Nothing else in this project renders the `+`'s card or the
/// thumbnail strip: they are a popover and a scroll view over a Liquid Glass bar, and
/// a suite of view models is blind to both.
///
/// So the assertions here are about *rectangles on the phone*: the card is above the
/// bar that opened it, the strip is above the text field rather than beside or below
/// it, and the picture's X is inside the tile it removes. None of those is arithmetic
/// a unit test could have checked.
///
/// # And it is where the screenshots come from
///
/// Each surface is attached to the result bundle as it is opened, which is how this
/// screen gets reviewed by someone who is not holding the phone. `xcresulttool export
/// attachments` takes them back out.
///
/// # What this does *not* prove
///
/// The system photo picker is Apple's. `PHPickerViewController` runs out of process,
/// but its remote view is hosted inside this app's own window, so it is reachable from
/// the same query tree — its thumbnails are *images* labelled `Photo, <date>` and there
/// are no cells at all, which is what an `app.cells` query silently finds nothing of.
/// Those two labels are the only thing here that belongs to a surface this project does
/// not own: if they change under a future iOS this test goes red without the app having
/// changed. It is written to fail loudly rather than skip, so that shows up as a
/// question rather than as a silent gap.
///
/// It also needs photos in the simulator's library:
/// `xcrun simctl addmedia <udid> <file>`.
final class ComposerAttachmentLayoutTests: XCTestCase {
    /// The accessibility labels the composer puts on what is measured here, repeated
    /// rather than imported: a UI-testing bundle drives the app from outside its
    /// process and links none of it.
    private enum Label {
        static let attach = "More options"
        static let photos = "Photos"
        static let camera = "Camera"
        static let send = "Send"
        static let removePicture = "Remove picture"
        /// What ``ComposerAttachmentStrip`` names a tile. The string is the whole
        /// contract between the halves — this bundle links none of the app.
        static let tile = "composerAttachment"
    }

    /// Apple's, not ours. The photo picker labels each thumbnail `Photo, <date>` and
    /// confirms with `Done`; those two strings are the only things this test knows
    /// about a surface it does not own. See the note at the top of the file.
    private enum PickerLabel {
        static let photoPrefix = "Photo,"
        static let confirm = "Done"
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    private func launchFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-fixtureConversation", "channel", "-messages=4"]
        app.launch()
        XCTAssertFalse(
            app.otherElements["fixtureFailure"].exists,
            "the fixture could not build its conversation"
        )
        return app
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The card

    /// The `+` opens a card *above* the bar, carrying both sources.
    func testAttachMenuOpensAboveTheComposer() {
        let app = launchFixture()

        let attachButton = app.buttons[Label.attach]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10), "the composer has no + control")
        let barTop = attachButton.frame.minY
        attachButton.tap()

        let photos = app.buttons[Label.photos]
        let camera = app.buttons[Label.camera]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "the card did not open")
        XCTAssertTrue(camera.exists, "the card is missing the Camera entry")

        attach(app.screenshot().image, named: "attach-menu")

        // Above the control that opened it — the whole point of a popover here rather
        // than a sheet, which iPhone would have brought up from the bottom of the
        // screen, over the bar it belongs to.
        XCTAssertLessThan(
            photos.frame.maxY, barTop,
            "the card is not above the composer: Photos ends at \(photos.frame.maxY), the + starts at \(barTop)"
        )
        // Photos first: it is the one that is built, and the one that will be used.
        XCTAssertLessThan(photos.frame.minY, camera.frame.minY)
        // Both rows clear the 44pt floor.
        XCTAssertGreaterThanOrEqual(photos.frame.height, 44)
        XCTAssertGreaterThanOrEqual(camera.frame.height, 44)
    }

    /// Camera says so rather than doing nothing, and the card gets out of the way
    /// first — a notice presented from inside a popover's own action is the race that
    /// drops one of the two.
    func testCameraReportsItIsNotBuiltYet() {
        let app = launchFixture()

        app.buttons[Label.attach].tap()
        XCTAssertTrue(app.buttons[Label.camera].waitForExistence(timeout: 5))
        app.buttons[Label.camera].tap()

        let notice = app.alerts.firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5), "Camera did nothing at all")
        attach(app.screenshot().image, named: "camera-not-built")
        notice.buttons["OK"].tap()
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 2))
    }

    // MARK: - The strip

    /// The whole path: pick a photo from the real library, watch it become a tile
    /// above the text field, and take it off again.
    func testAPickedPictureBecomesATileAboveTheTextAndCanBeRemoved() {
        let app = launchFixture()

        let attachButton = app.buttons[Label.attach]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10))
        let composerTop = attachButton.frame.minY
        attachButton.tap()

        XCTAssertTrue(app.buttons[Label.photos].waitForExistence(timeout: 5))
        app.buttons[Label.photos].tap()

        pickFirstPhoto(in: app)

        let tile = app.otherElements[Label.tile].firstMatch
        let remove = app.buttons[Label.removePicture].firstMatch
        XCTAssertTrue(
            remove.waitForExistence(timeout: 20),
            "the picked photo never became a tile in the composer"
        )
        attach(app.screenshot().image, named: "attachment-strip")

        // Above the text field, which is above the controls: the strip must not have
        // landed between the text and the send button.
        XCTAssertTrue(tile.exists, "the composer has no attachment tile")
        XCTAssertLessThan(
            tile.frame.maxY, composerTop,
            "the strip is not above the composer's control row"
        )
        // The X is inside the tile it removes, at its top-right — a target that hung
        // off the edge would reach the next picture across the gap.
        XCTAssertTrue(
            tile.frame.contains(CGPoint(x: remove.frame.midX, y: remove.frame.midY)),
            "the remove control sits outside the tile it belongs to"
        )
        XCTAssertGreaterThanOrEqual(remove.frame.height, 44, "the X is under the 44pt floor")

        // A picture on its own is a message, so send is live with the field empty.
        XCTAssertTrue(app.buttons[Label.send].isEnabled, "a picture alone did not enable send")

        remove.tap()
        XCTAssertTrue(
            waitForDisappearance(of: remove),
            "the X did not take the picture off"
        )
        XCTAssertFalse(app.buttons[Label.send].isEnabled, "send stayed live with nothing to send")
    }

    // MARK: - Driving Apple's picker

    /// Taps the first photo in the system picker and confirms it.
    ///
    /// `PHPickerViewController` runs out of process, so it is reached through its own
    /// application rather than the app under test. The two labels below are Apple's,
    /// which is why the note at the top of this file exists.
    private func pickFirstPhoto(in app: XCUIApplication) {
        // `PHPickerViewController` runs out of process, but its remote view is hosted
        // inside this app's own window, so its elements are reachable here. Its
        // thumbnails are *images* labelled `Photo, <date>` — there are no cells, which
        // is what a `app.cells` query silently finds nothing of.
        let photo = app.images
            .matching(NSPredicate(format: "label BEGINSWITH %@", PickerLabel.photoPrefix))
            .firstMatch
        XCTAssertTrue(
            photo.waitForExistence(timeout: 20),
            "the photo picker never showed a photo — is the simulator's library empty? "
                + "Seed it with `xcrun simctl addmedia <udid> <file>`"
        )
        // Through its centre rather than `tap()`: the picker reports its thumbnails as
        // not hittable — they are a remote view's images, and XCUITest will not press
        // an element it cannot prove is on top. A coordinate tap is the touch itself,
        // which is what a finger does anyway.
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // The picker is multi-select (up to `ComposerAttachmentsModel.selectionLimit`),
        // so a tap selects rather than dismisses and the confirmation is its own control.
        let confirm = app.buttons[PickerLabel.confirm]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the picker has no confirmation")
        XCTAssertTrue(confirm.isEnabled, "tapping a photo did not select it")
        confirm.tap()
    }

    private func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "settle")], timeout: 0.2)
        }
        return !element.exists
    }
}
