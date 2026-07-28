import BuzzKit
import SwiftUI
import UIKit

/// What the viewer was opened on: the attachment, and the bitmap that was already on
/// screen when it opened.
///
/// The preview is the reason the viewer never starts empty. The inline view is drawing a
/// downsampled copy of exactly this picture at the moment it is tapped, so handing it over
/// costs nothing and means the full-screen surface has real content in its first frame —
/// which is also what makes the zoom transition land on the picture rather than on a black
/// rectangle that becomes one.
struct MessageMediaViewerSubject: Identifiable {
    let media: MessageMedia
    /// The inline bitmap, when the inline view had one to give.
    let preview: UIImage?

    /// Keyed by URL, matching ``BuzzKit/MessageMedia/id`` and the transition source the
    /// inline view registers.
    var id: String { media.url }
}

/// One attachment, full screen, zoomable.
///
/// # What it is made of, and what each part is for
///
/// - **The picture** is ``MessageMediaZoomView``, a `UIScrollView` bridge, because pinch,
///   pan-within-bounds, double-tap-to-point and rubber-banding are what a reader expects
///   from a photograph and none of them exist in SwiftUI.
/// - **The decode** is the same ``RemoteImageLoader`` the inline view uses, asked for a
///   much larger pixel size (``MessageMediaLayout/viewerPixelSize(screen:displayScale:declared:)``).
///   Two entries for one attachment is the intended cost: the inline bitmap is a 320-pt
///   box's worth and would be mush blown up to the screen.
/// - **Dismissal** is a `Done` button *and* the zoom transition's own interactive drag.
///   The button is the one that is certain — it is a control, it is reachable by
///   VoiceOver, and it works whatever a gesture recogniser underneath decides. The drag is
///   the one that feels right, and ``MessageMediaZoomView`` disables the scroll view's pan
///   at the fitted scale so that it can begin.
///
/// # Why the background is black and the scheme is forced dark
///
/// A photograph is judged against what surrounds it, and a light chrome around a picture
/// tints the reader's sense of its exposure. Every system photo viewer does this. Forcing
/// the scheme rather than only the colour is what makes the `Done` button's glass and the
/// status bar legible on it in an app running in light appearance.
struct MessageMediaViewer: View {
    let subject: MessageMediaViewerSubject
    var loader: RemoteImageLoader = .messageMedia

    @State private var full: UIImage?
    @State private var didFail = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keyed by the pixel size rather than by the geometry: the target is derived
            // from the screen's *longest* edge, so a rotation cannot change it and cannot
            // re-run a decode that would produce the identical bitmap.
            .task(id: pixelSize(for: proxy.size)) {
                await load(pixelSize: pixelSize(for: proxy.size))
            }
        }
        .ignoresSafeArea()
        .overlay(alignment: .topTrailing) { doneButton }
        .preferredColorScheme(.dark)
    }
}

// MARK: - Content

private extension MessageMediaViewer {
    @ViewBuilder
    var content: some View {
        if let image = full ?? subject.preview {
            MessageMediaZoomView(image: image)
                // Labelled here rather than left to the bridge: a `UIImageView` reports
                // itself to VoiceOver as an unlabelled image, and the author's `alt` is the
                // only description of it that exists.
                .accessibilityElement()
                .accessibilityLabel(MessageMediaDescription.label(for: subject.media, state: .loaded))
                .accessibilityAddTraits(.isImage)
        } else if didFail {
            failureNotice
        } else {
            ProgressView()
                .controlSize(.large)
                .tint(.white)
        }
    }

    /// The failure state here can only be reached by opening the viewer on an attachment
    /// that has no inline bitmap either, which today means a `data:` payload that decodes
    /// at one size and not another — rare, and still not allowed to be a black rectangle
    /// with nothing in it.
    var failureNotice: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo")
                .font(.hiveSymbol(.largeTitle))
                .foregroundStyle(.white.opacity(0.7))
            Text(MessageMediaDescription.placeholderText(for: subject.media, state: .failed))
                .font(.hive(.callout))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    var doneButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.hiveSymbol(.body, weight: .semibold))
                // A minimum square rather than the glyph's own size: the system's 44-pt
                // target is the whole reason this is reachable with a thumb while the
                // other hand holds the phone.
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.glass)
        .accessibilityLabel("Done")
        .padding(.trailing, 16)
        .padding(.top, 8)
    }
}

// MARK: - Loading

private extension MessageMediaViewer {
    func pixelSize(for screen: CGSize) -> CGFloat {
        MessageMediaLayout.viewerPixelSize(
            screen: screen,
            displayScale: displayScale,
            declared: subject.media.pixelSize
        )
    }

    func load(pixelSize: CGFloat) async {
        guard subject.media.kind == .image, let url = URL(string: subject.media.url) else {
            didFail = subject.preview == nil
            return
        }
        // A cache hit answers without suspending and without a request; a miss shares the
        // fetch with anything else asking for the same picture at the same size.
        let image = await loader.image(for: url, pixelSize: pixelSize)
        guard !Task.isCancelled else { return }
        if let image {
            full = image
        } else {
            // Only a failure if there is nothing at all to show. Falling back to the
            // inline bitmap — soft, but the right picture — beats replacing a picture the
            // reader is already looking at with an apology.
            didFail = subject.preview == nil
        }
    }
}
