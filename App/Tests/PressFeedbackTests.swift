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
/// - a control drawn straight onto a message draws no shape;
/// - Reduce Motion takes the movement off and keeps the feedback;
/// - a press outlives the curve that draws it, and the action waits behind it;
/// - an abandoned press comes off faster than a released one, with no minimum in front of it;
/// - a pressed message actually puts ink on the screen, which is the only one of these that
///   no amount of reading the code can establish.
@Suite("Press feedback")
struct PressFeedbackTests {
    @Test("a pressed control shrinks by an amount a finger reads and a layout does not")
    func pressedScaleIsShallow() {
        // The brief's range. Below it the label re-lays out at the accessibility sizes;
        // above it nothing happened.
        #expect(PressFeedback.pressedScale >= 0.96)
        #expect(PressFeedback.pressedScale <= 0.97)
    }

    @Test("the press finishes and is held before anything else happens")
    func theShrinkHasRoomToArrive() {
        // The whole of the owner's third and fourth reports, as one inequality. The shrink
        // must *finish* — not merely be under way — and then be held, before the action that
        // replaces the screen is allowed to run. A press curve as long as the minimum is the
        // defect this exists to prevent: the control reaches full scale exactly as it is
        // taken away, which is what "the scale-down animation doesn't happen" looks like.
        #expect(PressFeedback.pressDuration < PressFeedback.minimumVisible)
        #expect(PressFeedback.minimumVisible - PressFeedback.pressDuration >= 0.08)
        // And the whole thing still lands inside the brief's "snappy".
        #expect(PressFeedback.pressDuration <= 0.2)
        #expect(PressFeedback.releaseDuration <= 0.2)
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

    @Test("a full-width row shrinks and washes like everything else")
    func rowShrinksAndWashes() {
        // It did not, once, on the reasoning that a row pulling in from both screen edges
        // reads as a card lifting off the list. The owner overruled that from a device: a row
        // is the thing he presses most, so an emphasis that opted out of the movement was an
        // app where the movement could not be seen.
        #expect(PressFeedback.scale(for: .row, reduceMotion: false) == PressFeedback.pressedScale)
        #expect(PressFeedback.fill(for: .row) > 0)
        // And it does not dim: a row that fades is a row that looks disabled.
        #expect(PressFeedback.dim(for: .row) == 1)
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
        #expect(PressFeedback.dim(for: .inline) < 1)
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

    @Test("every wash is drawn in the sidebar mark's own shape")
    func washMatchesTheSidebarMark() {
        // Compared as drawn paths, because that is the only thing a shape can be asked.
        // The owner's rule: the press highlight and ``ChannelListView/resumeMark`` are the
        // same highlight — same colour, same opacity, same corner, same inset — so a row and
        // a control both wash in a 10pt continuous rounded rectangle rather than the row
        // washing square as it first shipped.
        let box = CGRect(x: 0, y: 0, width: 100, height: 44)
        let mark = RoundedRectangle(cornerRadius: PressFeedback.cornerRadius, style: .continuous).path(in: box)
        #expect(PressFeedbackButtonStyle(.row).shape.path(in: box) == mark)
        #expect(PressFeedbackButtonStyle(.control).shape.path(in: box) == mark)
        // And a control that names its own shape keeps it.
        #expect(PressFeedbackButtonStyle(.control, in: .capsule).shape.path(in: box) == Capsule().path(in: box))
    }

    @Test("the highlight is the sidebar mark's colour and opacity, to the number")
    func washIsTheAccentAtTheMarksOpacity() {
        // The one that would silently drift: `resumeMark` fills `Color.hiveAccent` at 0.14,
        // and a press that used `.secondary` — as this did when it first shipped — is a
        // second highlight vocabulary in a list that already has one.
        #expect(PressFeedback.fillColor == Color.hiveAccent)
        #expect(PressFeedback.pressedFill == 0.14)
        #expect(PressFeedback.rowInset.horizontal == 8)
        #expect(PressFeedback.rowInset.vertical == 1)
    }

    @Test("a press stays on screen long enough to be seen")
    func aPressPlaysThrough() {
        // The defect this exists to prevent, reported from a device: a tap shorter than the
        // shrink means the shrink never arrives, so the control appears not to animate at
        // all. Whatever the minimum is, it has to outlast the ease-out that draws it.
        #expect(PressFeedback.minimumVisible > PressFeedback.pressDuration)
    }

    @Test("a control's claim on a tap outlasts the row tap it has to beat")
    func theArbitrationWindowOutlastsTheDeferral() {
        // Not a restatement of the constant: ``TimelineRowView/scheduleRowTap()`` now waits
        // ``PressFeedback/minimumVisible`` before opening a thread, so the press has somewhere
        // to be seen. A suppression window shorter than that wait would lapse before the
        // deferred tap asks about it — and a reaction chip's tap would send the reaction *and*
        // push the thread on top of it. The two numbers have to move together.
        #expect(RowTapArbitration.window > PressFeedback.minimumVisible)
    }

    @Test("down is the ease-out and up is the spring")
    func theTwoCurvesAreNotTheSame() {
        #expect(PressFeedback.animation(pressed: true, reduceMotion: false) == PressFeedback.press)
        #expect(PressFeedback.animation(pressed: false, reduceMotion: false) == PressFeedback.release)
        #expect(PressFeedback.press != PressFeedback.release)
    }
}

// MARK: - The message wash

@Suite("Message press glow")
@MainActor
struct MessagePressGlowTests {
    /// The size the wash is rendered over. Wider than the bleed it takes back out, so the
    /// comparison is looking at the part of the row a reader sees.
    private static let size = CGSize(width: 240, height: 60)

    @Test("a pressed message draws ink where a resting one draws none")
    func pressedMessageDrawsInk() throws {
        let resting = try #require(Self.render(pressed: false), "the resting render produced no image")
        let pressed = try #require(Self.render(pressed: true), "the pressed render produced no image")

        // Rendered, not reasoned about. The wash is a `Color` at a tenth opacity behind a
        // view that has no background of its own, and "an opacity was applied" is exactly
        // the kind of claim that survives the effect being clipped away, drawn under an
        // opaque parent, or resolved to nothing by a hierarchical style.
        let difference = try Self.difference(between: resting, and: pressed)
        #expect(difference > 0.01, "a pressed message differs from a resting one by only \(difference)")
    }

    @Test("the same message under no press is identical to itself")
    func restingMessageIsStable() throws {
        // The control for the test above: it says the difference measured there is the
        // wash, and not the renderer being nondeterministic.
        let first = try #require(Self.render(pressed: false))
        let second = try #require(Self.render(pressed: false))
        #expect(try Self.difference(between: first, and: second) == 0)
    }

    /// A message-shaped subject: text over the conversation, with nothing of its own behind
    /// it.
    ///
    /// The first version of this rendered the wash behind an opaque rectangle and measured a
    /// difference of exactly zero — a true reading of a test that had covered the thing it
    /// was looking at. That is the mistake worth keeping written down, because it is the one
    /// this whole suite is exposed to: the wash goes *behind* the row, so anything opaque in
    /// front of it hides it, and a row with a background of its own would hide it on the
    /// phone exactly as it did here. §3 says a message has no background; this is now also
    /// the reason it must not grow one.
    private static func render(pressed: Bool) -> UIImage? {
        let renderer = ImageRenderer(
            content: Text("Message")
                .frame(width: size.width, height: size.height)
                .messagePressGlow(pressed)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        renderer.scale = 1
        renderer.isOpaque = true
        return renderer.uiImage
    }

    /// Mean absolute per-channel difference, 0 for identical and 1 for black against white.
    /// Both images are redrawn into one known 8-bit context first, so the comparison is of
    /// pixels rather than of two encoders.
    private static func difference(between lhs: UIImage, and rhs: UIImage) throws -> Double {
        let left = try pixels(of: lhs)
        let right = try pixels(of: rhs)
        guard left.count == right.count, !left.isEmpty else { return 1 }
        var total = 0
        for index in left.indices {
            total += abs(Int(left[index]) - Int(right[index]))
        }
        return Double(total) / Double(left.count) / 255
    }

    private static func pixels(of image: UIImage) throws -> [UInt8] {
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
        return buffer
    }
}
