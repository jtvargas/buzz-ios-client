import CoreGraphics
@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The press vocabulary: what each emphasis does under a finger, and what a message does.
///
/// # What is worth asserting about a visual effect
///
/// Not that a scale is 0.965 — that is the constant restating itself. What these hold are
/// the *rules* the constants exist to express, each of which is invisible on a resting
/// screen and each of which a later hand can undo without noticing:
///
/// - every emphasis shrinks, a full-width row included;
/// - only a control with edges of its own washes: the owner had the amber taken off the
///   sidebar and off a message entirely;
/// - Reduce Motion takes the movement off and keeps the feedback;
/// - a press outlives the curve that draws it by nothing at all — it may never stand in front
///   of the action it is feedback for;
/// - an abandoned press comes off faster than a released one, with no minimum in front of it;
/// - a control inside a scroll view is handed the finger at touch-down rather than 150ms
///   later, which is the half of "the shrink doesn't happen" that no constant could fix;
/// - and the treatment actually moves ink on a screen, which is the only one of these that
///   no amount of reading the code can establish.
@Suite("Press feedback")
struct PressFeedbackTests {
    @Test("the shrink moves ink on the widest thing it is applied to, and stays subtle")
    func pressedScaleIsVisibleAndSubtle() {
        // Not the constant restating itself: the rule is that the movement has to be legible
        // on a full-width row — the thing the owner presses most, and the thing he reported
        // three times as not moving at all — without becoming the lurch that four per cent was.
        // Half the difference is what each edge travels on a 390pt phone.
        let edgeTravel = 390 * (1 - PressFeedback.pressedScale) / 2
        #expect(edgeTravel >= 4)
        #expect(edgeTravel <= 8)
        // The owner's range, once the 150ms delay in front of the press had been found and
        // removed: the depth was never what made the shrink invisible, so it went back to
        // subtle. Below 0.94 the label also visibly re-lays out at the accessibility text
        // sizes, which is a different defect wearing the same clothes.
        #expect(PressFeedback.pressedScale >= 0.97)
        #expect(PressFeedback.pressedScale <= 0.98)
    }

    @Test("the whole gesture is snappy, and nothing in it is a dwell")
    func theCurvesAreSnappy() {
        // 80–100ms down, the owner's range, and the range is the point rather than the
        // midpoint: below it a press is a jump with no animation to see, above it the control
        // is still moving when a quick finger has already gone.
        #expect(PressFeedback.pressDuration >= 0.08)
        #expect(PressFeedback.pressDuration <= 0.1)
        // And the release settles in about the same breath. It was once followed by a hold
        // that the button's action waited behind, and the owner's report on that build was
        // that the entire app felt delayed.
        #expect(PressFeedback.releaseDuration <= 0.25)
    }

    @Test("an abandoned press comes off faster than a released one")
    func cancelIsFasterThanRelease() {
        // The owner's first report: a highlight that survives the finger leaving is a
        // highlight that trails a scrolling list. It is not a release and must not look like
        // one — no spring, no overshoot, and short enough to be gone within a frame or two.
        #expect(PressFeedback.cancelDuration < PressFeedback.pressDuration)
        #expect(PressFeedback.cancelDuration < PressFeedback.releaseDuration)
        #expect(PressFeedback.cancel != PressFeedback.release)
    }

    @Test("a full-width row shrinks and draws no wash at all")
    func rowShrinksAndDoesNotWash() {
        // Both halves are the owner's, given in that order from a device. First: a row is the
        // thing he presses most, so an emphasis that opted out of the movement was an app
        // where the movement could not be seen — every emphasis shrinks now. Then: *remove
        // the highlight on pressing for the sidebar at all*, because the amber is already the
        // mark on the conversation you were last in, and a list that flashes it under every
        // finger is a list saying "this one" about whatever you happened to touch.
        #expect(PressFeedback.scale(for: .row, reduceMotion: false) == PressFeedback.pressedScale)
        #expect(PressFeedback.fill(for: .row) == 0)
        // What is left beside the movement: a few per cent of light, and not enough to read
        // as disabled.
        #expect(PressFeedback.dim(for: .row) < 1)
        #expect(PressFeedback.dim(for: .row) > 0.85)
    }

    @Test("a control shrinks and washes inside its own shape")
    func controlShrinksAndWashes() {
        #expect(PressFeedback.scale(for: .control, reduceMotion: false) == PressFeedback.pressedScale)
        #expect(PressFeedback.fill(for: .control) > 0)
        #expect(PressFeedback.dim(for: .control) == 1)
    }

    @Test("a control drawn onto a message shrinks and dims, and draws nothing")
    func inlineDrawsNothing() {
        #expect(PressFeedback.scale(for: .inline, reduceMotion: false) == PressFeedback.pressedScale)
        // The whole reason this emphasis exists: a shape here would turn part of a message
        // into a button.
        #expect(PressFeedback.fill(for: .inline) == 0)
        // And it fades further than a row does, because unlike a row it has nothing else at
        // all — no shape, no wash, and no edges for the movement to be read against.
        #expect(PressFeedback.dim(for: .inline) < PressFeedback.dim(for: .row))
    }

    @Test("Reduce Motion drops the movement from every emphasis and keeps the feedback")
    func reduceMotionKeepsTheWash() {
        for emphasis in [PressFeedbackButtonStyle.Emphasis.control, .row, .inline] {
            #expect(PressFeedback.scale(for: emphasis, reduceMotion: true) == 1)
        }
        #expect(PressFeedback.fill(for: .control) > 0)
        #expect(PressFeedback.dim(for: .inline) < 1)
        // And the release stops overshooting — a spring is the movement the setting declines.
        #expect(PressFeedback.animation(pressed: false, reduceMotion: true) == PressFeedback.press)
    }

    @Test("a wash is drawn in the sidebar mark's own shape unless the control names one")
    func washMatchesTheSidebarMark() {
        // Compared as drawn paths, because that is the only thing a shape can be asked.
        let box = CGRect(x: 0, y: 0, width: 100, height: 44)
        let mark = RoundedRectangle(cornerRadius: PressFeedback.cornerRadius, style: .continuous).path(in: box)
        #expect(PressFeedbackButtonStyle(.control).shape.path(in: box) == mark)
        // And a control that names its own shape keeps it: a wash in the wrong shape is more
        // visible than no wash at all.
        #expect(PressFeedbackButtonStyle(.control, in: .capsule).shape.path(in: box) == Capsule().path(in: box))
    }

    @Test("the highlight is the sidebar mark's colour and opacity, to the number")
    func washIsTheAccentAtTheMarksOpacity() {
        // The one that would silently drift: `resumeMark` fills `Color.hiveAccent` at 0.14,
        // and a press that used `.secondary` — as this did when it first shipped — is a
        // second highlight vocabulary in a list that already has one.
        #expect(PressFeedback.fillColor == Color.hiveAccent)
        #expect(PressFeedback.pressedFill == 0.14)
    }

    @Test("the press latch is the down-curve and not one millisecond of dwell more")
    func aPressPlaysThroughAndNoLonger() {
        // Two defects at once, and they pull in opposite directions.
        //
        // Shorter than the curve and the shrink never arrives: `isPressed` follows the finger
        // exactly, a quick tap ends mid-animation, and the control reads as not animating at
        // all. That was reported from a device three times.
        //
        // *Longer* than the curve and the latch becomes a dwell — which is what it was when
        // it also held the button's action back, and the owner's report on that build was
        // that the whole app felt delayed. Equality is the only value that is neither, so it
        // is asserted as equality rather than as a range: if this line has to be relaxed,
        // the question being answered is "how long should a control stall for?", and the
        // answer to that question is that it should not.
        #expect(PressFeedback.minimumVisible == PressFeedback.pressDuration)
    }

    @Test("down is the ease-out and up is the spring")
    func theTwoCurvesAreNotTheSame() {
        #expect(PressFeedback.animation(pressed: true, reduceMotion: false) == PressFeedback.press)
        #expect(PressFeedback.animation(pressed: false, reduceMotion: false) == PressFeedback.release)
        #expect(PressFeedback.press != PressFeedback.release)
    }
}

// MARK: - The delay in front of the press

/// The half of *"the scale-down is not happening"* that no constant could have fixed.
///
/// Reported three times from a device, and answered twice with a bigger number before the
/// cause turned out to be UIKit's: a scroll view holds the touches landing on its content
/// while it decides whether a scroll is beginning, so a control inside a list is not told it
/// was pressed until about 150ms after it was. See ``ScrollTouchDeliveryView``.
@Suite("Immediate press feedback")
@MainActor
struct ScrollTouchDeliveryTests {
    @Test("a control inside a scroll view is handed the finger at touch-down")
    func theDelayComesOff() {
        let scrollView = UIScrollView()
        let content = UIView()
        scrollView.addSubview(content)
        let control = UIView()
        content.addSubview(control)

        // UIKit's default, and so the defect: asserted rather than assumed, because the whole
        // fix is that this is `true` everywhere until something says otherwise.
        #expect(scrollView.delaysContentTouches)

        ScrollTouchDeliveryView.deliverImmediately(above: control)

        #expect(!scrollView.delaysContentTouches)
        // And the pan must still be able to take the touch back, or a press that turns into a
        // scroll would never be cancelled — which is the owner's other rule, in the other
        // direction: *the highlight must disappear as soon as the finger moves.*
        #expect(scrollView.canCancelContentTouches)
    }

    @Test("every scrolling ancestor loses the delay, not just the nearest")
    func nestedScrollViewsBothComeOff() {
        // A reaction chip sits in a horizontal scroll view inside the conversation's own, and
        // the outer one delays the touch before the inner one ever sees it. Stopping at the
        // first scrolling ancestor would leave that chip exactly as late as it was.
        let outer = UIScrollView()
        let inner = UIScrollView()
        outer.addSubview(inner)
        let control = UIView()
        inner.addSubview(control)

        let reached = ScrollTouchDeliveryView.deliverImmediately(above: control)

        #expect(reached.count == 2)
        #expect(!inner.delaysContentTouches)
        #expect(!outer.delaysContentTouches)
    }

    @Test("a control outside any scroll view is left alone")
    func nothingToHurryAlong() {
        let loose = UIView()
        UIView().addSubview(loose)
        #expect(ScrollTouchDeliveryView.deliverImmediately(above: loose).isEmpty)
    }
}

// MARK: - The treatment, rendered

/// What a press *looks* like, measured off a bitmap.
///
/// `ImageRenderer` can render a view and cannot press a button, which is why
/// ``PressTreatment`` is a modifier over a plain `Bool` rather than something only a
/// `ButtonStyle` can reach. Everything above this line is a rule about a number; these are the
/// two claims that were reported wrong from a device three times running — *the scale-down is
/// not happening* and *the highlight is still there* — held to actual ink.
@Suite("Press treatment, rendered")
@MainActor
struct PressTreatmentRenderTests {
    /// The subject's size, and the canvas around it. The canvas is wider so a shrinking
    /// subject has somewhere to shrink *to* that is still in the picture.
    private static let subject = CGSize(width: 240, height: 60)
    private static let canvas = CGSize(width: 300, height: 100)
    private static let white: [UInt8] = [255, 255, 255]

    @Test("a pressed control's ink actually moves, by the scale it claims")
    func pressedInkShrinks() throws {
        let resting = try Self.inkBox(of: #require(Self.render(pressed: false, emphasis: .row, ink: .black)))
        let pressed = try Self.inkBox(of: #require(Self.render(pressed: true, emphasis: .row, ink: .black)))

        // The subject drew at its full size at rest — the control for everything below.
        #expect(abs(resting.width - Self.subject.width) <= 1)
        // And under a press it is narrower by the scale, within a pixel of antialiasing at
        // each edge. "A `scaleEffect` was applied" is exactly the kind of claim that survives
        // the effect being applied to the label instead of the control, or being animated
        // from a value that never changes.
        let expected = Self.subject.width * PressFeedback.pressedScale
        #expect(abs(pressed.width - expected) <= 2)
        // Stated once more as the thing a person would notice, so the rule survives someone
        // moving the constant: the row got visibly narrower. Six points across a 240pt subject
        // is the floor a three-per-cent shrink leaves — it is deliberately not tightened to
        // the current number, because the number is the owner's dial and this is the rule.
        #expect(resting.width - pressed.width >= 6)
    }

    @Test("the same view under no press is identical to itself")
    func restingIsStable() throws {
        // The control for the test above: it says the movement measured there is the press,
        // and not the renderer being nondeterministic.
        let first = try #require(Self.render(pressed: false, emphasis: .row, ink: .black))
        let second = try #require(Self.render(pressed: false, emphasis: .row, ink: .black))
        #expect(try Self.inkBox(of: first) == Self.inkBox(of: second))
    }

    @Test("a control washes its own shape and a full-width row washes nothing")
    func onlyAControlWashes() throws {
        // The owner's instruction, on pixels: *remove the highlight on pressing for the
        // sidebar at all.* Rendered with a transparent subject, so the only thing that can
        // put colour in the middle of the canvas is the wash behind it.
        let control = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .control, ink: .clear)))
        let row = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .row, ink: .clear)))
        #expect(control != Self.white, "a pressed control drew no wash")
        #expect(row == Self.white, "a pressed row drew a wash the owner had removed")
    }

    private static func render(
        pressed: Bool,
        emphasis: PressFeedbackButtonStyle.Emphasis,
        ink: Color
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: ZStack {
                Color.white
                ink
                    .frame(width: subject.width, height: subject.height)
                    .pressTreatment(isShowing: pressed, emphasis: emphasis)
            }
            .frame(width: canvas.width, height: canvas.height)
            .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// The bounding box of everything darker than mid-grey — where the subject landed.
    private static func inkBox(of image: UIImage) throws -> CGRect {
        let bitmap = try pixels(of: image)
        var minX = bitmap.width, maxX = -1, minY = bitmap.height, maxY = -1
        for row in 0 ..< bitmap.height {
            for column in 0 ..< bitmap.width where bitmap.isInk(row: row, column: column) {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return .zero }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// The middle pixel, as red/green/blue.
    private static func centre(of image: UIImage) throws -> [UInt8] {
        let bitmap = try pixels(of: image)
        return bitmap.colour(row: bitmap.height / 2, column: bitmap.width / 2)
    }

    /// An image redrawn into one known 8-bit context, so a comparison is of pixels rather
    /// than of two encoders.
    private struct Bitmap {
        let buffer: [UInt8]
        let width: Int
        let height: Int

        func colour(row: Int, column: Int) -> [UInt8] {
            let index = (row * width + column) * 4
            return Array(buffer[index ..< (index + 3)])
        }

        func isInk(row: Int, column: Int) -> Bool {
            let channels = colour(row: row, column: column).map(Int.init)
            return channels.reduce(0, +) / channels.count < 128
        }
    }

    private static func pixels(of image: UIImage) throws -> Bitmap {
        let cgImage = try #require(image.cgImage, "image has no bitmap")
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(
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
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return Bitmap(buffer: buffer, width: width, height: height)
    }
}
