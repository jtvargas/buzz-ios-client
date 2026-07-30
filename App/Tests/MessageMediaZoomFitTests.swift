@testable import Hive
import Testing
import UIKit

/// What the full-screen picture is laid out at.
///
/// # Why this suite exists
///
/// The viewer draws the inline bitmap first and swaps in the full-resolution decode a
/// moment later, and the swap re-lays the image view. That second layout shipped broken:
/// a scroll view zooms by putting a **transform** on the view it is zooming, `UIView.frame`
/// is derived from `bounds` *through* that transform, and so assigning a frame to an
/// already-scaled view made UIKit divide the previous scale back out. Every picture that
/// had been on screen a moment before it was tapped — which is every single attachment and
/// every mosaic cell a reader actually taps — opened cropped, showing about its top-left
/// quadrant.
///
/// It was invisible to the suite because nothing here had ever asked what the picture was
/// laid out at, and invisible to arithmetic because the *scroll view* was right the whole
/// time: it reported the correct fitted `zoomScale` while the view under it was the wrong
/// size. So every assertion below is on the **image view's own frame** — what a reader
/// actually sees — and never on `zoomScale`, which is the number that lied.
@MainActor
@Suite("Message media zoom fit")
struct MessageMediaZoomFitTests {
    /// A viewport the size of the room the viewer leaves a picture on a tall phone, once
    /// the status bar, the header and the home indicator have taken theirs.
    static let viewport = CGSize(width: 402, height: 778)

    /// A blank bitmap of `size`, at scale 1 so its `size` is its pixel count — which is
    /// what a downsampled decode hands the viewer.
    static func image(_ size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// A coordinator attached to a scroll view of `viewport`, already showing `first`.
    ///
    /// **In a window, and laid out.** A scroll view applies the zoom as a transform on the
    /// view it is zooming during layout, so a bare `UIScrollView` built in memory reports
    /// the arithmetic without ever performing it — which is not a smaller version of the
    /// device, it is a different machine. Measured: the first draft of this suite built one
    /// that way and the headline test **passed against the broken code**. The window and
    /// the `layoutIfNeeded` below are what make a failure here mean a crop on the phone.
    static func fitted(
        first: CGSize,
        in viewport: CGSize = MessageMediaZoomFitTests.viewport
    ) -> (MessageMediaZoomView.Coordinator, MessageMediaScrollView, UIImageView, UIWindow) {
        let window = UIWindow(frame: CGRect(origin: .zero, size: viewport))
        let scrollView = MessageMediaScrollView()
        scrollView.frame = CGRect(origin: .zero, size: viewport)
        let imageView = UIImageView(image: image(first))
        scrollView.addSubview(imageView)
        window.addSubview(scrollView)
        window.isHidden = false
        let coordinator = MessageMediaZoomView.Coordinator(
            maximumMagnification: MessageMediaZoomView.maximumMagnification
        )
        coordinator.attach(scrollView: scrollView, imageView: imageView)
        scrollView.delegate = coordinator
        coordinator.fitToBounds(preservingMagnification: false)
        window.layoutIfNeeded()
        return (coordinator, scrollView, imageView, window)
    }

    /// The size a picture of `image` comes out at when fitted into `viewport`, to the
    /// tolerance a chain of divisions deserves.
    static func expectedFit(image: CGSize, viewport: CGSize = MessageMediaZoomFitTests.viewport) -> CGSize {
        let scale = min(viewport.width / image.width, viewport.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

extension MessageMediaZoomFitTests {
    /// The defect, from the failing side: show a picture, then replace it the way the
    /// full-resolution decode replaces the inline preview.
    ///
    /// Before the fix this came out at 960x960 — 1200 ÷ 0.41875 × 0.335, the preview's
    /// fitted scale divided back out of the frame — against a 402pt viewport.
    @Test("replacing the picture lays the new one out fitted, not scaled by the old one's zoom")
    func replacedPictureIsFitted() {
        let (coordinator, _, imageView, window) = Self.fitted(first: CGSize(width: 960, height: 960))
        coordinator.show(Self.image(CGSize(width: 1200, height: 1200)))
        window.layoutIfNeeded()

        let expected = Self.expectedFit(image: CGSize(width: 1200, height: 1200))
        #expect(abs(imageView.frame.width - expected.width) < 0.5)
        #expect(abs(imageView.frame.height - expected.height) < 0.5)
    }

    /// Every shape the viewer has to answer for, replaced from a preview of the same shape
    /// at the resolution the inline box decodes to. A picture is *whole* exactly when it
    /// fits inside the viewport on both axes.
    @Test(
        "a replaced picture of any shape lands inside the viewport",
        arguments: [
            CGSize(width: 900, height: 1600),
            CGSize(width: 1600, height: 700),
            CGSize(width: 1200, height: 1200),
            CGSize(width: 300, height: 200),
        ]
    )
    func replacedPictureFitsTheViewport(size: CGSize) {
        let previewScale = min(1, 960 / max(size.width, size.height))
        let preview = CGSize(width: size.width * previewScale, height: size.height * previewScale)
        let (coordinator, _, imageView, window) = Self.fitted(first: preview)
        coordinator.show(Self.image(size))
        window.layoutIfNeeded()

        #expect(imageView.frame.width <= Self.viewport.width + 0.5)
        #expect(imageView.frame.height <= Self.viewport.height + 0.5)
        // And it fills one of the two, or it is not fitted — it is merely small.
        let fillsWidth = abs(imageView.frame.width - Self.viewport.width) < 0.5
        let fillsHeight = abs(imageView.frame.height - Self.viewport.height) < 0.5
        #expect(fillsWidth || fillsHeight)
    }

    /// The aspect ratio survives the replacement. A fit that squashed a picture to the
    /// viewport would pass the bounds check above and be worse than the crop it replaced.
    @Test("a replaced picture keeps its aspect ratio")
    func replacedPictureKeepsItsShape() {
        let (coordinator, _, imageView, window) = Self.fitted(first: CGSize(width: 480, height: 854))
        coordinator.show(Self.image(CGSize(width: 900, height: 1600)))
        window.layoutIfNeeded()

        let ratio = imageView.frame.width / imageView.frame.height
        #expect(abs(ratio - 900.0 / 1600.0) < 0.01)
    }

    /// A reader who had zoomed in keeps their magnification across the swap — the reason
    /// `preservingMagnification` exists, and the thing the fix must not have cost.
    @Test("a magnified reader keeps their magnification when the full decode lands")
    func magnificationSurvivesTheSwap() {
        let (coordinator, scrollView, imageView, window) = Self.fitted(first: CGSize(width: 960, height: 960))
        scrollView.zoomScale = scrollView.minimumZoomScale * 2
        coordinator.show(Self.image(CGSize(width: 1200, height: 1200)))
        window.layoutIfNeeded()

        let expected = Self.expectedFit(image: CGSize(width: 1200, height: 1200))
        #expect(abs(imageView.frame.width - expected.width * 2) < 1)
        #expect(abs(scrollView.zoomScale / scrollView.minimumZoomScale - 2) < 0.01)
    }

    /// A rotation, which is the other caller: same bounds change, no new picture.
    @Test("a picture re-fits when the viewport changes")
    func refitsOnANewViewport() {
        let (coordinator, scrollView, imageView, window) = Self.fitted(first: CGSize(width: 1200, height: 1200))
        scrollView.frame = CGRect(origin: .zero, size: CGSize(width: 778, height: 402))
        coordinator.fitToBounds(preservingMagnification: true)
        window.layoutIfNeeded()

        let expected = Self.expectedFit(
            image: CGSize(width: 1200, height: 1200),
            viewport: CGSize(width: 778, height: 402)
        )
        #expect(abs(imageView.frame.height - expected.height) < 0.5)
    }

    /// The fitted scale is the floor, so a reader can never pinch a picture smaller than
    /// whole — and the ceiling stays where the type says it is.
    @Test("the fitted scale is the minimum and the magnification limit is relative to it")
    func limitsAreRelativeToTheFit() {
        let (coordinator, scrollView, _, window) = Self.fitted(first: CGSize(width: 960, height: 960))
        coordinator.show(Self.image(CGSize(width: 1200, height: 1200)))
        window.layoutIfNeeded()

        #expect(abs(scrollView.zoomScale - scrollView.minimumZoomScale) < 0.001)
        #expect(
            abs(
                scrollView.maximumZoomScale
                    - scrollView.minimumZoomScale * MessageMediaZoomView.maximumMagnification
            ) < 0.001
        )
    }
}
