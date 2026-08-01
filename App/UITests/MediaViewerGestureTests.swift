import XCTest

/// That the picture still answers a finger after Live Text was put on it.
///
/// # Why this exists
///
/// `ImageAnalysisInteraction` is attached to the `UIImageView` inside the viewer's scroll
/// view, and making that possible required `isUserInteractionEnabled = true` on a view that
/// ships with it off. Both are exactly the construction that has broken this app before: a
/// gesture added to something inside a scroll view claimed the touch, and the surface
/// underneath went dead while every existing test stayed green. That cost a shipped build in
/// `#105`, where a conversation could not be scrolled at all and both a full suite and an
/// independent review passed it.
///
/// The viewer's own suite could not have caught the same thing here. It opens a picture and
/// measures rectangles; it never drags to dismiss. So the gesture this interaction could
/// plausibly take is asserted here, and nowhere else.
///
/// # Why zoom and pan are not asserted, having been tried
///
/// They are not observable from outside the process. ``MessageMediaViewerPage`` publishes the
/// zoom view as a *single* accessibility element for the page, so the frame XCUITest reports
/// is the page's — the whole window — at every magnification. A first draft here asserted that
/// a double tap grew the picture and read 874pt before and 874pt after; running it with the
/// interaction **detached** produced exactly the same numbers, which is what says the
/// assertion was measuring the wrong thing rather than catching a defect.
///
/// The fit arithmetic those gestures drive is gated in `MessageMediaZoomFitTests`, in process,
/// where the scroll view's own scale is readable.
///
/// # What this can and cannot say
///
/// The interaction is attached on every device. Whether Live Text *analyses* anything is
/// `ImageAnalyzer.isSupported`, which is hardware-dependent and may be `false` on a simulator
/// — so a green run here is evidence that the interaction has not stolen the gestures, and is
/// **not** evidence that text became selectable. That second half is a device check, and it is
/// flagged as one rather than claimed.
final class MediaViewerGestureTests: XCTestCase {
    /// A picture with real text in it would be the honest subject for Live Text itself, but
    /// the fixture's shapes are generated fields of colour — which is fine for what is asked
    /// here, since the interaction is attached whether or not it finds anything to select.
    private static let shape = (shape: "Column", alt: "Column picture")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testDraggingDownStillDismissesWithLiveTextAttached() {
        let app = openViewer()
        defer { app.terminate() }

        let picture = app.images[Self.shape.alt]
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "the viewer did not open on the picture")

        // The drag begins ON the picture, which is the whole point: that is the view the
        // interaction was added to, and a gesture it claimed would take this one.
        app.swipeDown(velocity: .fast)

        let inline = app.buttons[Self.shape.alt]
        XCTAssertTrue(
            inline.waitForExistence(timeout: 10),
            "dragging down did not dismiss the viewer — Live Text has taken the dismissal gesture"
        )
    }

    /// The share button is a control on the picture, and one the reader cannot reach is not
    /// one. Its own presence is asserted in ``MediaViewerLayoutTests``' drawing; this says it
    /// is in front of a picture that now has an interaction over it.
    ///
    /// Reachability, deliberately, and not *enabled*: the control arms when the original bytes
    /// land, and the fixture has no media host to fetch them from, so it stays disabled here
    /// for the honest reason. What can be said on a simulator is that the picture layer — which
    /// is the whole window — has not swallowed it.
    func testTheShareButtonIsReachableOverThePicture() {
        let app = openViewer()
        defer { app.terminate() }

        let share = app.buttons["Share picture"]
        XCTAssertTrue(share.waitForExistence(timeout: 10), "the viewer has no share button")
        XCTAssertTrue(
            share.isHittable,
            "the share button is on screen but is behind the picture"
        )
    }

    private func openViewer() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-fixtureConversation", "channel", "-messages=2", "-imageShape=\(Self.shape.shape)",
        ]
        app.launch()
        XCTAssertFalse(
            app.otherElements["fixtureFailure"].exists,
            "the fixture could not build its conversation"
        )
        let inline = app.buttons[Self.shape.alt]
        XCTAssertTrue(inline.waitForExistence(timeout: 20), "the picture never rendered")
        inline.tap()
        return app
    }
}
