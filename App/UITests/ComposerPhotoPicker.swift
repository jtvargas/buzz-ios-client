import XCTest

/// Driving Apple's photo picker from a UI test.
///
/// Shared by the two suites that need a real attachment on screen —
/// ``ComposerAttachmentLayoutTests``, which measures the strip, and
/// ``ComposerGrowthTests``, which measures what the strip does to the conversation
/// behind it. The labels below are the only strings in this bundle that belong to a
/// surface this project does not own, so they are written down once rather than in
/// both suites.
///
/// It needs photos in the simulator's library:
/// `xcrun simctl addmedia <udid> <file>`.
extension XCTestCase {
    /// What the composer names the controls this drives. Repeated rather than
    /// imported: a UI-testing bundle drives the app from outside its process and
    /// links none of it.
    enum ComposerLabel {
        static let attach = "More options"
        static let photos = "Photos"
        static let camera = "Camera"
        static let send = "Send"
        static let removePicture = "Remove picture"
        /// What ``ComposerAttachmentStrip`` names a tile. The string is the whole
        /// contract between the halves.
        static let tile = "composerAttachment"
    }

    /// Apple's, not ours. The photo picker labels each thumbnail `Photo, <date>` and
    /// confirms with `Done`. If those change under a future iOS the suites using this
    /// go red without the app having changed — written to fail loudly rather than
    /// skip, so that shows up as a question rather than as a silent gap.
    private enum PickerLabel {
        static let photoPrefix = "Photo,"
        static let confirm = "Done"
    }

    /// The whole pick: `+`, Photos, the first thumbnail, Done, and the tile that
    /// results.
    ///
    /// Returns once the picture is on the bar, which is the moment the bar has its
    /// new height.
    func attachOnePicture(to app: XCUIApplication, timeout: TimeInterval = 20) {
        let attachButton = app.buttons[ComposerLabel.attach]
        XCTAssertTrue(attachButton.waitForExistence(timeout: 10), "the composer has no + control")
        attachButton.tap()

        let photos = app.buttons[ComposerLabel.photos]
        XCTAssertTrue(photos.waitForExistence(timeout: 5), "the + card did not open")
        photos.tap()

        pickFirstPhoto(in: app)

        XCTAssertTrue(
            app.buttons[ComposerLabel.removePicture].firstMatch.waitForExistence(timeout: timeout),
            "the picked photo never became a tile in the composer"
        )
    }

    /// Taps the first photo in the system picker and confirms it.
    ///
    /// `PHPickerViewController` runs out of process, but its remote view is hosted
    /// inside this app's own window, so its elements are reachable from the same
    /// query tree. Its thumbnails are *images* labelled `Photo, <date>` — there are
    /// no cells at all, which is what an `app.cells` query silently finds nothing of.
    func pickFirstPhoto(in app: XCUIApplication) {
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
}
