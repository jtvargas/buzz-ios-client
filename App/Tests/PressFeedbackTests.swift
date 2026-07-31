import CoreGraphics
@testable import Hive
import SwiftUI
import Testing
import UIKit

/// The press vocabulary: what each emphasis does under a finger, and what a message does.
///
/// # What is worth asserting about a visual effect
///
/// Not that a number is 0.14 — that is the constant restating itself. What these hold are
/// the *rules* the constants exist to express, each of which is invisible on a resting
/// screen and each of which a later hand can undo without noticing:
///
/// - **nothing moves.** The owner had the scale removed outright after five rounds of it, so
///   the strongest assertion in this file is a negative one, measured on pixels: a pressed row
///   lands in exactly the box the resting one did;
/// - only a control with edges of its own washes: the owner had the amber taken off the
///   sidebar and off a message entirely;
/// - a press outlives the curve that draws it by nothing at all — it may never stand in front
///   of the action it is feedback for;
/// - an abandoned press comes off faster than a released one, with no minimum in front of it;
/// - a control inside a scroll view is handed the finger at touch-down rather than 150ms
///   later, which is the half of "the press can't be seen" that no constant could fix;
/// - and the treatment actually puts light on a screen, which is the only one of these that
///   no amount of reading the code can establish.
@Suite("Press feedback")
struct PressFeedbackTests {
    @Test("there is no scale, and it is gone rather than dialled to one")
    func nothingInTheTreatmentScales() {
        // The owner's fifth and final word on it: *"forget about it, I don't want that scale
        // animation."* This is asserted as an absence at the type level — `PressFeedback` has
        // no scale constant and `PressTreatment` has no `scaleEffect` — and the reason it also
        // gets a test is that an absence is the one thing a diff review is worst at noticing.
        // `nothingMovesUnderAPress` below is the half of this claim that measures pixels; this
        // half exists so the file that *names* the treatment says so too.
        //
        // What is left is light, and only light: a control washes, a row and an inline control
        // dim, and every one of those is checked below.
        #expect(PressFeedback.fill(for: .control) > 0)
        #expect(PressFeedback.dim(for: .row) < 1)
        #expect(PressFeedback.dim(for: .inline) < 1)
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
        // one — short enough to be gone within a frame or two of the finger moving.
        #expect(PressFeedback.cancelDuration < PressFeedback.pressDuration)
        #expect(PressFeedback.cancelDuration < PressFeedback.releaseDuration)
        #expect(PressFeedback.cancel != PressFeedback.release)
    }

    @Test("a full-width row dims and draws no wash at all")
    func rowDimsAndDoesNotWash() {
        // The owner's, given from a device in this order: *remove the highlight on pressing
        // for the sidebar at all* — because the amber is already the mark on the conversation
        // you were last in, and a list that flashes it under every finger is a list saying
        // "this one" about whatever you happened to touch — and then, a round later, the scale
        // as well. So a row's entire answer to a finger is the line below it.
        #expect(PressFeedback.fill(for: .row) == 0)
        // A few per cent of light, and not so much that a pressed row reads as disabled.
        #expect(PressFeedback.dim(for: .row) < 1)
        #expect(PressFeedback.dim(for: .row) > 0.85)
    }

    @Test("a control washes inside its own shape and does not dim")
    func controlWashes() {
        #expect(PressFeedback.fill(for: .control) > 0)
        // It has a wash; fading its label as well would be saying the same thing twice.
        #expect(PressFeedback.dim(for: .control) == 1)
    }

    @Test("a control drawn onto a message dims, and draws nothing")
    func inlineDrawsNothing() {
        // The whole reason this emphasis exists: a shape here would turn part of a message
        // into a button.
        #expect(PressFeedback.fill(for: .inline) == 0)
        // And it fades further than a row does, because unlike a row it has nothing else at
        // all — no shape, no wash, and no edges to be read against.
        #expect(PressFeedback.dim(for: .inline) < PressFeedback.dim(for: .row))
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
        // Shorter than the curve and the press never arrives: `isPressed` follows the finger
        // exactly, a quick tap ends mid-animation, and the control reads as not answering at
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

    @Test("down is quick and up is given longer to settle")
    func theTwoCurvesAreNotTheSame() {
        #expect(PressFeedback.animation(pressed: true) == PressFeedback.press)
        #expect(PressFeedback.animation(pressed: false) == PressFeedback.release)
        #expect(PressFeedback.press != PressFeedback.release)
        #expect(PressFeedback.pressDuration < PressFeedback.releaseDuration)
    }
}

// MARK: - The delay in front of the press

/// The half of *"the press feedback can't be seen"* that no constant could have fixed.
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
    /// The subject's size, and the canvas around it. The canvas is wider than the subject so
    /// that a treatment which moved it — which none may — would have somewhere to move *to*
    /// that is still in the picture, and the measurement below could see it.
    private static let subject = CGSize(width: 240, height: 60)
    private static let canvas = CGSize(width: 300, height: 100)
    private static let white: [UInt8] = [255, 255, 255]

    @Test("a pressed row does not move by so much as a pixel")
    func nothingMovesUnderAPress() throws {
        let resting = try Self.inkBox(of: #require(Self.render(pressed: false, emphasis: .row, ink: .black)))
        let pressed = try Self.inkBox(of: #require(Self.render(pressed: true, emphasis: .row, ink: .black)))

        // The subject drew at its full size at rest — the control for everything below.
        #expect(abs(resting.width - Self.subject.width) <= 1)
        // And it drew in exactly the same place under a press. This is the owner's instruction
        // held to pixels: he had the scale removed after five rounds of it, and "there is no
        // longer a `scaleEffect` in that file" is precisely the kind of claim that a later
        // hand undoes in one line while adding something else. A tolerance of one pixel is
        // antialiasing, not movement — the shrink this replaces moved a 240pt subject by 7.
        #expect(abs(pressed.width - resting.width) <= 1)
        #expect(abs(pressed.height - resting.height) <= 1)
        #expect(abs(pressed.minX - resting.minX) <= 1)
    }

    @Test("a pressed row answers with light, since it no longer answers with movement")
    func aPressedRowIsLighter() throws {
        // The other side of the test above, and the reason it is not enough on its own: with
        // the movement gone, a treatment that did nothing at all would pass it. A row's whole
        // answer is now the dim, so the dim is measured — black ink over white, so a fade
        // toward the background can only make the middle of the subject lighter.
        let resting = try Self.centre(of: #require(Self.render(pressed: false, emphasis: .row, ink: .black)))
        let pressed = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .row, ink: .black)))
        #expect(pressed[0] > resting[0], "a pressed row drew no lighter than a resting one")
    }

    @Test("the same view under no press is identical to itself")
    func restingIsStable() throws {
        // The control for the two tests above: it says the ink box measured there is stable,
        // so "it did not move" is a fact about the treatment and not about the renderer
        // happening to agree with itself.
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
