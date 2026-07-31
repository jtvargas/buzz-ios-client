import XCTest

/// What a message looks like while a finger is on it.
///
/// # Why this cannot be a unit test
///
/// ``MessagePressGlowTests`` renders the wash and proves it puts ink on the screen — but it
/// hands the modifier a `Bool`, so it would go on passing if nothing ever set that `Bool`
/// true. The claim worth making is the one it cannot reach: that the press the row *already
/// recognises* reports itself, through an `exclusively(before:)` composition, on a row
/// inside a live scroll view that is entitled to steal the touch at any moment.
///
/// That is exactly where this could silently do nothing. The round that first asked for
/// pressed feedback on a message found that a recogniser watching for touch-down costs the
/// list its scrolling, and settled for a flash on release; this one takes the state off the
/// long press instead, which costs the gesture nothing — if it reports at touch-down. Only a
/// real finger on a real list can say.
///
/// # How a held press is observed
///
/// `press(forDuration:)` blocks until the finger lifts, so the press is issued from a
/// background queue and the screen is read from the test thread while it is still down. The
/// press is deliberately shorter than the row's 0.35s recognition, so the actions sheet
/// never opens and what is measured is the press itself rather than the sheet arriving.
final class MessagePressFeedbackTests: ConversationScrollHarness {
    /// Held shorter than ``TimelineRowView``'s `longPressDuration`, so the sheet stays shut.
    private static let holdDuration: TimeInterval = 0.25

    /// When the screen is read, measured from the moment the press is issued. Past the ease-out
    /// the wash animates over, and well inside the hold.
    private static let readAfter: TimeInterval = 0.12

    func testAMessageLightsUpWhileItIsHeld() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=8"])
        // A row from the *readable* band, not simply the newest: the newest sits against the
        // composer and may be half under it, and a region that is partly composer is a region
        // where the wash cannot be measured. `readable` is bounded by whichever of the
        // keyboard and the composer reaches highest, so a row from it is a row on screen.
        let band = readableBand(app)
        let row = try XCTUnwrap(
            readable(app).last { $0.frame.minY > band.minY && $0.frame.maxY < band.maxY },
            "no message row sits wholly inside the readable band"
        )
        XCTAssertGreaterThan(row.frame.height, 0, "the row to press has no height")

        let resting = XCUIScreen.main.screenshot().image
        let pressed = try holdAndCapture(app, at: CGPoint(x: row.frame.midX, y: row.frame.midY))

        attach(resting, named: "message-resting")
        attach(pressed, named: "message-pressed")

        let difference = try difference(between: resting, and: pressed, in: row.frame)
        // A tenth-opacity wash over the row's own area. The threshold is well under what that
        // produces and well over the noise between two screenshots of a still screen, which
        // the control below measures.
        XCTAssertGreaterThan(
            difference,
            0.002,
            "a held message differs from a resting one by only \(difference) — the press is not reaching the row"
        )

        // The control. Without it a difference above could be anything the screen did on its
        // own — a relative timestamp ticking over, a blur settling — and the assertion would
        // pass on a build where the wash was never drawn.
        let restingAgain = XCUIScreen.main.screenshot().image
        let noise = try self.difference(between: resting, and: restingAgain, in: row.frame)
        XCTAssertLessThan(noise, difference, "the screen changed as much on its own as it did under a finger")
    }

    /// The control for the test above, and a claim in its own right: the composer's `+` takes
    /// the `control` emphasis, so a finger on it shrinks and washes it.
    ///
    /// If this fails while the message test passes, the vocabulary is not reaching controls.
    /// If both fail, the harness is not reading the screen while the finger is down — which
    /// is a different bug, in this file rather than in the app.
    func testAComposerControlAnswersAPress() throws {
        let app = launch(["-fixtureConversation", "channel", "-messages=8"])
        let plus = app.buttons["More options"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5), "no attach button on screen")

        let resting = XCUIScreen.main.screenshot().image
        let pressed = try holdAndCapture(app, at: CGPoint(x: plus.frame.midX, y: plus.frame.midY))
        attach(pressed, named: "control-pressed")

        let difference = try difference(between: resting, and: pressed, in: plus.frame)
        XCTAssertGreaterThan(
            difference,
            0.002,
            "a held control differs from a resting one by only \(difference)"
        )
    }

    // MARK: - Driving

    /// Holds a finger on `point` and reads the screen while it is still down.
    ///
    /// The press runs on the test thread and the *screenshot* is what moves off it, which is
    /// the opposite of the obvious arrangement and the only one that works: `press(forDuration:)`
    /// raises `Must be called on the main thread` from a background queue, so the finger cannot
    /// be the thing dispatched. A screen read can be.
    private func holdAndCapture(_ app: XCUIApplication, at point: CGPoint) throws -> UIImage {
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let target = origin.withOffset(CGVector(dx: point.x, dy: point.y))
        let read = expectation(description: "the screen was read under the finger")
        let image = Captured()
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + Self.readAfter) {
            image.value = XCUIScreen.main.screenshot().image
            read.fulfill()
        }
        target.press(forDuration: Self.holdDuration)
        wait(for: [read], timeout: 10)
        return try XCTUnwrap(image.value, "no screenshot was taken while the finger was down")
    }

    /// A box for the screenshot, so the closure above writes somewhere the test can read
    /// without capturing a `var` across threads.
    private final class Captured: @unchecked Sendable {
        var value: UIImage?
    }

    private func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        // Kept whether or not the test failed: this suite is where a reviewer who is not
        // holding the phone sees what a pressed message looks like.
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Reading pixels

    /// Mean absolute per-channel difference over `region`, 0 for identical and 1 for black
    /// against white.
    ///
    /// `region` arrives in points, from an element frame; a screenshot is in pixels. Scaling
    /// it by the image's own scale is the whole reason this is not a one-liner — comparing a
    /// point rectangle against a pixel buffer reads a third of the intended row on this phone
    /// and none of it on a phone with a different scale.
    private func difference(between lhs: UIImage, and rhs: UIImage, in region: CGRect) throws -> Double {
        let left = try pixels(of: lhs, in: region)
        let right = try pixels(of: rhs, in: region)
        guard left.count == right.count, !left.isEmpty else {
            XCTFail("the two screenshots cover different areas: \(left.count) against \(right.count)")
            return 0
        }
        var total = 0
        for index in left.indices {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(left.count) / 255
    }

    private func pixels(of image: UIImage, in region: CGRect) throws -> [UInt8] {
        let cgImage = try XCTUnwrap(image.cgImage, "screenshot has no bitmap")
        let scale = CGFloat(cgImage.width) / image.size.width
        let scaled = CGRect(
            x: region.minX * scale,
            y: region.minY * scale,
            width: region.width * scale,
            height: region.height * scale
        ).integral
        let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let cropped = try XCTUnwrap(cgImage.cropping(to: scaled.intersection(bounds)), "the row is off the screenshot")

        let width = cropped.width
        let height = cropped.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(
            CGContext(
                data: &buffer,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            "could not build a comparison context"
        )
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}
