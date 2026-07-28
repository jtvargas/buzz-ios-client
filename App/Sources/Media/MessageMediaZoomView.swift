import SwiftUI
import UIKit

/// A picture that pinches, double-taps and pans, in a `UIScrollView`.
///
/// # Why UIKit for this and nothing else in the feature
///
/// `MagnifyGesture` bound to a `scaleEffect` is the SwiftUI answer and it is not the same
/// thing. What a reader expects from a photograph is the whole of `UIScrollView`'s
/// zooming behaviour, and every part of it is work someone would otherwise write badly:
/// zoom anchored between the fingers rather than at the view's centre, panning bounded to
/// the picture's edges at every scale, rubber-banding past those edges, momentum, and
/// double-tap-to-zoom that lands on the point that was tapped. There is no first-party
/// SwiftUI construction that provides them, so this is a bridge rather than a
/// reimplementation, and it is the only one in the feature.
///
/// # The two things that are easy to get wrong here
///
/// **Centring is `contentInset`, not a frame.** A picture smaller than the scroll view —
/// which is every picture at its fitted scale — has to be pushed to the middle by insetting
/// the content, because moving the image view's frame instead fights the scroll view's own
/// bounds arithmetic and lands the picture off-centre as soon as it is zoomed.
///
/// **Scrolling is switched off at the fitted scale.** With nothing to pan, the scroll
/// view's pan recogniser still claims the touch, and the presentation's own interactive
/// dismissal — a drag down on the picture — never begins. Disabling `isScrollEnabled`
/// disables the *pan* and leaves pinch and double-tap alone, which is exactly the split
/// this needs.
struct MessageMediaZoomView: UIViewRepresentable {
    /// The picture to show. Replacing it — the inline bitmap giving way to the
    /// full-resolution decode — keeps the reader's current magnification.
    let image: UIImage

    /// How far past its fitted size a picture may be magnified.
    ///
    /// Relative to the fitted scale rather than absolute, so the limit means the same
    /// thing for a large photograph and a small one. Four is enough to read text in a
    /// screenshot, which is what people zoom into a chat picture for; past that a decode
    /// bounded at ``MessageMediaLayout/viewerMaximumPixelSize`` has no more detail to show
    /// and it is only magnifying its own pixels.
    static let maximumMagnification: CGFloat = 4

    func makeUIView(context: Context) -> MessageMediaScrollView {
        let scrollView = MessageMediaScrollView()
        scrollView.delegate = context.coordinator
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        // The picture is drawn edge to edge under the status bar, so the scroll view must
        // not inset its content for one.
        scrollView.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        context.coordinator.attach(scrollView: scrollView, imageView: imageView)
        // The scroll view learns its own size after this returns, so the fitted scale is
        // computed from `layoutSubviews` rather than here, where the bounds are still zero.
        scrollView.onSizeChange = { [weak coordinator = context.coordinator] in
            coordinator?.fitToBounds(preservingMagnification: true)
        }
        return scrollView
    }

    func updateUIView(_ scrollView: MessageMediaScrollView, context: Context) {
        context.coordinator.show(image)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(maximumMagnification: Self.maximumMagnification)
    }
}

// MARK: - The scroll view

/// A `UIScrollView` that says when its bounds changed.
///
/// `UIViewRepresentable` has no layout hook, and the fitted scale cannot be computed
/// before the view has a size — so the one thing this subclass exists for is to report
/// that it now has one, and to report it again on a rotation. Guarded on the size actually
/// changing: `layoutSubviews` runs on every scroll and on every zoom step, and
/// re-deriving the zoom scale from inside it would be a layout that invalidates itself.
final class MessageMediaScrollView: UIScrollView {
    /// Explicitly `@MainActor` in the function type. `UIView` already isolates this class
    /// to the main actor, but a stored closure's *type* carries no isolation of its own,
    /// so without the annotation the body could not call main-actor work under complete
    /// concurrency checking.
    var onSizeChange: (@MainActor () -> Void)?
    private var lastReportedSize: CGSize = .zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, bounds.size != lastReportedSize else { return }
        lastReportedSize = bounds.size
        onSizeChange?()
    }
}

// MARK: - Coordinator

extension MessageMediaZoomView {
    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        private let maximumMagnification: CGFloat
        private weak var scrollView: MessageMediaScrollView?
        private weak var imageView: UIImageView?

        init(maximumMagnification: CGFloat) {
            self.maximumMagnification = maximumMagnification
        }

        func attach(scrollView: MessageMediaScrollView, imageView: UIImageView) {
            self.scrollView = scrollView
            self.imageView = imageView
        }

        /// Shows `image`, keeping the reader where they were.
        ///
        /// The identity check is not an optimisation: `updateUIView` runs on every pass of
        /// SwiftUI's update, and re-seating the same bitmap would reset the zoom out from
        /// under a reader who was mid-pinch.
        func show(_ image: UIImage) {
            guard let imageView, imageView.image !== image else { return }
            imageView.image = image
            // The replacement is the same picture at a higher resolution, so its shape is
            // unchanged and preserving the *relative* magnification keeps the swap
            // invisible — the fitted scale changes, what is on screen does not.
            fitToBounds(preservingMagnification: true)
        }

        /// Recomputes the fitted scale for the current bounds.
        func fitToBounds(preservingMagnification: Bool) {
            guard let scrollView, let imageView, let size = imageView.image?.size,
                  size.width > 0, size.height > 0,
                  scrollView.bounds.width > 0, scrollView.bounds.height > 0
            else { return }

            let magnification = preservingMagnification && scrollView.minimumZoomScale > 0
                ? scrollView.zoomScale / scrollView.minimumZoomScale
                : 1

            // The image view is laid out at the bitmap's own size and then *scaled* by the
            // scroll view; that is what makes `zoomScale` mean "points per pixel" and what
            // keeps the pan bounds correct at every step.
            imageView.frame = CGRect(origin: .zero, size: size)
            scrollView.contentSize = size

            let fitted = min(scrollView.bounds.width / size.width, scrollView.bounds.height / size.height)
            scrollView.minimumZoomScale = fitted
            scrollView.maximumZoomScale = fitted * maximumMagnification
            scrollView.zoomScale = min(fitted * max(1, magnification), scrollView.maximumZoomScale)
            centreContent()
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centreContent()
        }

        // MARK: Gestures

        @objc
        func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            // A hair above the minimum rather than equal to it: the fitted scale is a
            // division, and a zoom that came back through `setZoomScale` is not always the
            // same float it went in as.
            guard scrollView.zoomScale <= scrollView.minimumZoomScale * 1.01 else {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }
            let target = min(scrollView.minimumZoomScale * 3, scrollView.maximumZoomScale)
            guard target > scrollView.minimumZoomScale else { return }
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / target
            let height = scrollView.bounds.height / target
            scrollView.zoom(
                to: CGRect(x: point.x - width / 2, y: point.y - height / 2, width: width, height: height),
                animated: true
            )
        }

        // MARK: Centring

        /// Pushes a picture smaller than the viewport into the middle of it, and hands the
        /// pan back to the presentation when there is nothing left to pan.
        private func centreContent() {
            guard let scrollView, let imageView else { return }
            // After a zoom the image view's `frame` already reports the scaled rectangle,
            // which is the quantity to compare against the viewport.
            let horizontal = max(0, (scrollView.bounds.width - imageView.frame.width) / 2)
            let vertical = max(0, (scrollView.bounds.height - imageView.frame.height) / 2)
            scrollView.contentInset = UIEdgeInsets(
                top: vertical,
                left: horizontal,
                bottom: vertical,
                right: horizontal
            )
            // See the type's note: with nothing to pan the recogniser would otherwise
            // swallow the drag that dismisses the viewer. The half-point of slack is for
            // the fitted scale itself, where one edge of the picture lands *on* the
            // viewport's and a float comparison would call that scrollable.
            scrollView.isScrollEnabled = imageView.frame.width > scrollView.bounds.width + 0.5
                || imageView.frame.height > scrollView.bounds.height + 0.5
        }
    }
}
