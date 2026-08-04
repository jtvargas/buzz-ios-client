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
/// - **the shrink is 2.5% and it is centred.** The owner had the scale removed outright after
///   five rounds of it and then asked for it back on 2026-08-04, so the assertion that used to
///   be a negative measured on pixels is now a positive one measured the same way: a pressed
///   row lands 2.5% narrower than the resting one, and in the middle of where it was;
/// - **Reduce Motion takes the shrink and leaves the light**, which is what that setting
///   actually asks for — a cross-fade in place of a movement, not the absence of feedback;
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
    @Test("a control and a row shrink; a control drawn onto a message does not")
    func theShrinkAppliesWhereItCanBeSeenAsDepth() {
        // The owner rejected 0.94 and 0.97 across five rounds before removing the scale
        // outright, then asked for 0.975. The band rather than the number: below about 0.96 it
        // is a squeeze rather than an answer, and at 0.99 it is not visible on a phone.
        #expect(PressFeedback.pressedScale >= 0.96)
        #expect(PressFeedback.pressedScale < 1)
        #expect(PressFeedback.scale(for: .control) == PressFeedback.pressedScale)
        #expect(PressFeedback.scale(for: .row) == PressFeedback.pressedScale)
        // And the exception that is the reason `scale(for:)` exists at all. The sender's name
        // and face draw straight onto a message's own text with no shape of their own, so a
        // shrink there reflows the paragraph around them — the sentence under the finger moves,
        // which is a much louder event than a control answering.
        #expect(PressFeedback.scale(for: .inline) == 1)

        // Light is still the rest of the answer, unchanged.
        #expect(PressFeedback.fill(for: .control) > 0)
        #expect(PressFeedback.dim(for: .row) < 1)
        #expect(PressFeedback.dim(for: .inline) < 1)
    }

    @Test("Reduce Motion drops the movement and keeps the light")
    func reduceMotionTakesTheShrinkOnly() {
        // The setting asks for a cross-fade *in place of* a movement, not for no feedback. So
        // the curves stop being springs — a spring with nothing left to spring is only a slower
        // fade — and the wash and dim are untouched. The pixel half is `reduceMotionDoesNotMove`.
        #expect(PressFeedback.animation(pressed: true, reduceMotion: true) != PressFeedback.press)
        #expect(PressFeedback.animation(pressed: false, reduceMotion: true) != PressFeedback.release)
        // And with it off, the accessor is the plain one rather than a third set of curves.
        #expect(PressFeedback.animation(pressed: true, reduceMotion: false) == PressFeedback.press)
        #expect(PressFeedback.animation(pressed: false, reduceMotion: false) == PressFeedback.release)
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

    @Test("a full-width row washes and dims, at the same strength a control washes")
    func rowWashesAndDims() {
        // The owner's, and it has been both ways. *Remove the highlight on pressing for the
        // sidebar at all* — because at 0.14 the wash was the resume mark to the number, and a
        // list that flashes the place mark under every finger is a list saying "this one"
        // about whatever you happened to touch. Then, on 2026-08-04, *some highlight container
        // with the same accent color but very dim*. Both are satisfied by the strength rather
        // than by the emphasis, which is what `washIsDimmerThanThePlaceItCouldBeConfusedWith`
        // holds: a row may wash as long as it cannot be read as the mark.
        #expect(PressFeedback.fill(for: .row) == PressFeedback.pressedFill)
        // And it keeps the dim on top — a few per cent of light, and not so much that a
        // pressed row reads as disabled.
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

    @Test("the highlight is the accent, and dimmer than the mark it must not be mistaken for")
    func washIsDimmerThanThePlaceItCouldBeConfusedWith() {
        // Two halves that pull against each other, which is why they are asserted together.
        //
        // Same *hue*, because a press that used `.secondary` — as this did when it first
        // shipped — is a second highlight vocabulary in a list that already has one.
        #expect(PressFeedback.fillColor == Color.hiveAccent)

        // Different *strength*, because being the same hue at the same opacity is exactly what
        // got this wash removed from the sidebar: `ChannelListView.resumeMark` fills
        // `Color.hiveAccent` at 0.14 to mark the conversation you were last in, and a press
        // drawn at 0.14 is that claim made about whatever your finger is touching. The owner
        // asked for 0.08. **This inequality is the load-bearing part** — equalise the two and
        // the row wash has to come off again, so it is asserted rather than left to the
        // literal below it.
        #expect(PressFeedback.pressedFill < Self.resumeMarkOpacity)
        #expect(PressFeedback.pressedFill == 0.08)
        // And still a highlight rather than nothing: 0.00 → 0.08 → 0.00 is the owner's own
        // notation, and the first of those zeroes is the resting state, not the peak.
        #expect(PressFeedback.pressedFill > 0)
    }

    /// `ChannelListView.resumeMark`'s own opacity — **the real one**, not a copy.
    ///
    /// It was a restated literal for one commit, because the value was buried in a
    /// `@ViewBuilder` no test could reach. Aligning the press wash with the mark's rectangle
    /// meant naming that geometry anyway, and the opacity came out with it, so this now reads
    /// the constant the view actually draws. A restated number would have passed forever after
    /// someone changed the mark.
    private static let resumeMarkOpacity = ChannelListView.markOpacity

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
        // that the whole app felt delayed.
        //
        // **A spring dissolves the dilemma rather than balancing it.** It reverses from
        // wherever it currently is, carrying its velocity, so a quick tap gives a small real
        // dip with no latch at all — where an ease-out could only jump to a new curve. The
        // owner asked for exactly that in two of his bullets at once: *"quick taps reverse
        // smoothly before the scale-down finishes"* and *"no artificial delay"*. So the latch
        // is zero, and asserted as zero rather than deleted, because it is the first dial to
        // turn if a quick tap now reads as too faint.
        #expect(PressFeedback.minimumVisible == 0)
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

    @Test("a pressed row shrinks by the stated amount, and shrinks toward its own centre")
    func aPressedRowShrinks() throws {
        let resting = try Self.inkBox(of: #require(Self.render(pressed: false, emphasis: .row, ink: .black)))
        let pressed = try Self.inkBox(of: #require(Self.render(pressed: true, emphasis: .row, ink: .black)))

        // The subject drew at its full size at rest — the control for everything below.
        #expect(abs(resting.width - Self.subject.width) <= 1)

        // It shrank, and by the number rather than by *some* amount: a `scaleEffect` left on a
        // stale constant is the failure this catches, and "it moved" would pass against any
        // value at all. One pixel of tolerance is antialiasing.
        let expected = Self.subject.width * PressFeedback.pressedScale
        #expect(abs(pressed.width - expected) <= 1, "expected \(expected)pt wide, drew \(pressed.width)")

        // And it came in from *both* edges. A row is four times wider than it is tall, so a
        // shrink anchored anywhere but the centre moves one edge by the whole 2.5% while the
        // other stays put — which reads as the row being tugged sideways rather than pressed.
        // Asserted on the centre line, which is the one thing an anchor cannot fake.
        #expect(abs(pressed.midX - resting.midX) <= 1, "the shrink was not centred")
    }

    @Test("Reduce Motion leaves the row exactly where it was")
    func reduceMotionDoesNotMove() throws {
        // The pixel half of `reduceMotionTakesTheShrinkOnly`. This is the assertion the old
        // suite made unconditionally, kept for the reader who asked for it — and it is worth
        // keeping in this shape because it is the one place the *absence* of movement is still
        // a requirement rather than a preference.
        let resting = try Self.inkBox(of: #require(
            Self.render(pressed: false, emphasis: .row, ink: .black, reduceMotion: true)
        ))
        let pressed = try Self.inkBox(of: #require(
            Self.render(pressed: true, emphasis: .row, ink: .black, reduceMotion: true)
        ))

        #expect(abs(pressed.width - resting.width) <= 1)
        #expect(abs(pressed.height - resting.height) <= 1)
        #expect(abs(pressed.minX - resting.minX) <= 1)
    }

    @Test("a pressed row answers with light, since it no longer answers with movement")
    func aPressedRowIsLighter() throws {
        // The other side of the test above, and the reason it is not enough on its own: a
        // treatment that *only* moved would pass that one. A row draws no wash, so its light is
        // the dim — black ink over white, so a fade toward the background can only make the
        // middle of the subject lighter.
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

    @Test("a control and a row both wash; a control drawn onto a message does not")
    func aWashIsDrawnWhereverThereIsAShapeToDrawItIn() throws {
        // The owner's instruction on pixels — *some highlight container with the same accent
        // color but very dim* — and the reason it is measured rather than read off the
        // constant: at 0.08 over white the difference is about six values in one channel, which
        // is small enough that a wash silently failing to draw would look exactly like a wash
        // drawing correctly to anyone reading the code.
        //
        // Rendered with a transparent subject, so the only thing that can put colour in the
        // middle of the canvas is the wash behind it.
        let control = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .control, ink: .clear)))
        let row = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .row, ink: .clear)))
        let inline = try Self.centre(of: #require(Self.render(pressed: true, emphasis: .inline, ink: .clear)))
        let resting = try Self.centre(of: #require(Self.render(pressed: false, emphasis: .control, ink: .clear)))

        #expect(control != Self.white, "a pressed control drew no wash")
        #expect(row != Self.white, "a pressed row drew no wash")
        // Both at the same strength: a row that washed *differently* from a control would be a
        // second highlight vocabulary, which is the thing `fillColor` exists to prevent.
        #expect(control == row, "a row washed at a different strength from a control")
        // And the exclusion that is not about strength. The sender's name and face sit on a
        // message's own text with no shape of their own, so a wash there is a lit rectangle
        // around a run of a sentence.
        #expect(inline == Self.white, "a control drawn onto a message drew a wash")
        // The first zero in the owner's `0.00 → 0.08 → 0.00`: a highlight that is not there
        // until a finger is.
        #expect(resting == Self.white, "a resting control drew a wash")
    }

    private static func render(
        pressed: Bool,
        emphasis: PressFeedbackButtonStyle.Emphasis,
        ink: Color,
        reduceMotion: Bool = false
    ) -> UIImage? {
        let renderer = ImageRenderer(
            content: ZStack {
                Color.white
                ink
                    .frame(width: subject.width, height: subject.height)
                    .pressTreatment(isShowing: pressed, emphasis: emphasis, reduceMotion: reduceMotion)
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
