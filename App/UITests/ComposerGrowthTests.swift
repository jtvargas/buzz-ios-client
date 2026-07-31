import XCTest

/// What attaching a picture does to the conversation behind the composer.
///
/// # Why this is its own suite
///
/// ``ConversationScrollTests`` drives the same shapes through a rising *keyboard*, which
/// takes room off the bottom of the scrollable region from outside the app. A picture takes
/// room off the same edge from inside it: the strip is 72 points of tile above the text
/// field, so the bar the scaffold insets by grows by about that much in one step.
///
/// The two are the same question — *does the newest message stay above the composer?* — and
/// the answer was known to differ. ``ConversationScaffold`` corrects the keyboard case and
/// says in as many words that a growing composer is *not* wired to it, because most shapes
/// follow unaided (a scroll view resting against its bottom has its offset clamped up when an
/// inset takes room there) and the ones that do not are those whose content landed after the
/// first layout. That is a claim about the shipping surface with no test under it. This is the
/// test.
///
/// # Every assertion is a row frame
///
/// For ``ConversationScrollHarness``' reason: the scroll view's own numbers are estimates on a
/// `LazyVStack` and an assertion built on them passes while the screen is blank.
///
/// It needs photos in the simulator's library —
/// `xcrun simctl addmedia <udid> <file>` — and drives Apple's picker, which
/// ``ComposerPhotoPicker`` documents.
final class ComposerGrowthTests: ConversationScrollHarness {
    /// Three of the eight, and which three is the point.
    ///
    /// `thread-8-longlast` rests on a message taller than the viewport, which is the shape
    /// where "is the newest message readable" and "is its *bottom edge* above the composer"
    /// stop being the same question. `thread-8-longlast-primed` is the same content delivered
    /// one relay round trip later — the shape that moved **0** points for a 311-point keyboard,
    /// and the one this suite exists to watch. `channel-50-plain` is the ordinary case, and is
    /// here so a fix that helps the awkward shapes and breaks the common one cannot pass.
    ///
    /// Not all eight: each one drives the system photo picker, which is a launch, two modal
    /// presentations and an out-of-process query apiece.
    private static let growthShapes = ["thread-8-longlast", "thread-8-longlast-primed", "channel-50-plain"]

    private static var shapesUnderTest: [Shape] {
        shapes.filter { growthShapes.contains($0.name) }
    }

    /// Open a conversation, touch nothing, attach a picture.
    ///
    /// Deliberately without focusing the composer first, so the keyboard is not in the
    /// picture: the only thing that changes between the two readings is the bar's own height.
    /// (Nothing restores focus that was never taken — see ``ComposerAttachButton``.)
    ///
    /// Three assertions per shape, mirroring the keyboard suite for the same reasons:
    ///
    /// 1. **The strip took real room.** A run where the bar did not grow asserts nothing, and
    ///    would compare a resting layout against itself — the failure mode that made 32 green
    ///    keyboard readings meaningless on 2026-07-27.
    /// 2. **The newest message's bottom edge clears the composer.** Not "is it readable": a
    ///    row taller than the screen intersects the band with its last 74 points buried.
    /// 3. **It moved by what the strip took, neither less nor more.** A one-sided bound admits
    ///    zero, which is the defect.
    func testAttachingAPictureKeepsTheNewestMessageAboveTheComposer() {
        for shape in Self.shapesUnderTest {
            let app = launch(shape.arguments)
            defer { app.terminate() }

            let bandBefore = readableBand(app)
            print("SHAPE \(shape.name) before \(describe(app))")
            XCTAssertFalse(readable(app).isEmpty, "\(shape.name): opened with no message readable")
            guard let newestBefore = rendered(app).last else {
                XCTFail("\(shape.name): nothing rendered")
                continue
            }

            attachOnePicture(to: app)
            // The strip appears with the pick and the correction follows the layout it causes;
            // both are inside a frame or two, and this is the same settle the keyboard suite
            // allows.
            Thread.sleep(forTimeInterval: 1.5)

            let band = readableBand(app)
            let growth = max(0, bandBefore.height - band.height)
            print("SHAPE \(shape.name) after  \(describe(app)) growth=\(Int(growth))")

            XCTAssertGreaterThan(
                growth,
                0,
                "\(shape.name): the strip took no room from the readable band, so this shape asserted nothing"
            )
            XCTAssertFalse(
                readable(app).isEmpty,
                "\(shape.name): BLANK — no message readable after attaching a picture"
            )
            guard let newestAfter = rendered(app).first(where: { $0.index == newestBefore.index }) else {
                XCTFail("\(shape.name): the newest message stopped being rendered when the picture was attached")
                continue
            }
            XCTAssertLessThanOrEqual(
                newestAfter.frame.maxY, band.maxY + 8,
                """
                \(shape.name): the last \(Int(newestAfter.frame.maxY - band.maxY))pt of the newest \
                message is under the attachment strip
                """
            )
            let moved = newestBefore.frame.minY - newestAfter.frame.minY
            XCTAssertEqual(
                moved, growth, accuracy: 8,
                """
                \(shape.name): the newest message moved \(Int(moved))pt \
                where the strip took \(Int(growth))pt
                """
            )
        }
    }

    /// The control, and the other half of the rule: a reader who has scrolled up into history
    /// is not moved by a picture being attached at the bottom of a screen they are not looking
    /// at.
    ///
    /// Asserted as a bound rather than an equality, because two outcomes are both correct —
    /// the content slides up by what the strip took, or it stays put. Moving *further* than
    /// the strip is the defect, and so is a conversation that yanks itself back to the newest
    /// message under someone reading something else.
    func testAttachingAPictureDoesNotMoveAReaderInHistory() {
        for shape in Self.shapesUnderTest {
            let app = launch(shape.arguments)
            defer { app.terminate() }

            app.windows.firstMatch.swipeDown(velocity: .slow)
            Thread.sleep(forTimeInterval: 1.5)
            let parked = rendered(app)
            let bandBefore = readableBand(app)
            print("SHAPE \(shape.name) parked \(describe(app))")
            guard let anchor = readable(app).first else {
                XCTFail("\(shape.name): nothing readable after scrolling up")
                continue
            }

            attachOnePicture(to: app)
            Thread.sleep(forTimeInterval: 1.5)

            let growth = max(0, bandBefore.height - readableBand(app).height)
            print("SHAPE \(shape.name) attached \(describe(app)) growth=\(Int(growth))")
            XCTAssertGreaterThan(growth, 0, "\(shape.name): the strip took no room, so this shape asserted nothing")
            XCTAssertFalse(
                readable(app).isEmpty,
                "\(shape.name): BLANK after attaching a picture from a scrolled-up position"
            )
            if let before = parked.first(where: { $0.index == anchor.index }),
               let after = rendered(app).first(where: { $0.index == anchor.index }) {
                let moved = before.frame.minY - after.frame.minY
                XCTAssertLessThanOrEqual(
                    abs(moved), growth + 8,
                    """
                    \(shape.name): a reader in history was moved \(Int(moved))pt \
                    where the strip took \(Int(growth))pt
                    """
                )
            }
        }
    }
}
