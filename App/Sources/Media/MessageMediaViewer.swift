import BuzzKit
import SwiftUI
import UIKit

/// What the viewer was opened on: every picture in the group it was opened from, which
/// one was tapped, and the bitmap that was already on screen for that one.
///
/// A single attachment opens this with a one-element `media` and `startIndex` 0, so its
/// behaviour is unchanged from before grouping existed — it is a gallery of one, not a
/// second case to keep in step.
///
/// The preview is the reason the tapped page never starts empty. The inline view — or a
/// mosaic cell — is drawing a downsampled copy of exactly that picture at the moment it is
/// tapped, so handing it over costs nothing and means the full-screen surface has real
/// content in its first frame, which is also what makes the zoom transition land on the
/// picture rather than on a black rectangle that becomes one. The other pages in the group
/// carry no preview; they were not on screen a moment ago, so there is nothing to hand
/// over.
struct MessageMediaViewerSubject: Identifiable {
    /// Every picture the reader can page to, in reading order.
    let media: [MessageMedia]
    /// Which of ``media`` was tapped, and so which page the viewer opens on.
    let startIndex: Int
    /// The inline bitmap for `media[startIndex]`, when the view that opened this had one
    /// to give.
    let preview: UIImage?

    /// Keyed by the tapped picture's URL, matching ``BuzzKit/MessageMedia/id`` and the
    /// transition source the view that opened this registers.
    var id: String { media[startIndex].url }
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

    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(subject: MessageMediaViewerSubject, loader: RemoteImageLoader = .messageMedia) {
        self.subject = subject
        self.loader = loader
        self._selection = State(initialValue: subject.startIndex)
    }

    var body: some View {
        GeometryReader { proxy in
            // The picture runs edge to edge and the button does not. Both children of one
            // stack, with only the pages ignoring the safe area: an overlay on a view
            // that has already ignored it inherits the same full-bleed frame, which puts
            // the button under the clock.
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                TabView(selection: $selection) {
                    ForEach(Array(subject.media.enumerated()), id: \.element.id) { index, media in
                        MessageMediaViewerPage(
                            media: media,
                            preview: index == subject.startIndex ? subject.preview : nil,
                            screenSize: proxy.size,
                            loader: loader
                        )
                        .tag(index)
                    }
                }
                // Paging only earns its chrome once there is more than one page — a
                // single attachment's viewer must read exactly as it did before
                // grouping existed, dots and all.
                .tabViewStyle(.page(indexDisplayMode: subject.media.count > 1 ? .automatic : .never))
                .ignoresSafeArea()
                doneButton
            }
        }
        .preferredColorScheme(.dark)
    }
}

// MARK: - One page

/// One picture of the gallery, full screen. Its own load and its own failure notice,
/// because each page decodes a different source at whatever pixel size the shared screen
/// geometry implies for *its* declared dimensions — the one thing neighbouring pages
/// cannot answer for each other.
private struct MessageMediaViewerPage: View {
    let media: MessageMedia
    /// The bitmap already on screen when this page's gallery was opened, or `nil` for
    /// every page but the one that was tapped — see ``MessageMediaViewerSubject``.
    let preview: UIImage?
    /// The viewer's own bounds, read once by the container's `GeometryReader` rather than
    /// once per page: every page targets the same screen, so there is nothing for a
    /// second reader to learn that the first one has not already.
    let screenSize: CGSize
    var loader: RemoteImageLoader

    @State private var full: UIImage?
    @State private var didFail = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keyed by the pixel size rather than by the geometry: the target is derived
            // from the screen's *longest* edge, so a rotation cannot change it and cannot
            // re-run a decode that would produce the identical bitmap.
            .task(id: pixelSize) {
                await load(pixelSize: pixelSize)
            }
    }
}

private extension MessageMediaViewerPage {
    @ViewBuilder
    var content: some View {
        if let image = full ?? preview {
            MessageMediaZoomView(image: image)
                // Labelled here rather than left to the bridge: a `UIImageView` reports
                // itself to VoiceOver as an unlabelled image, and the author's `alt` is the
                // only description of it that exists.
                .accessibilityElement()
                .accessibilityLabel(MessageMediaDescription.label(for: media, state: .loaded))
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
            Text(MessageMediaDescription.placeholderText(for: media, state: .failed))
                .font(.hive(.callout))
                .foregroundStyle(.white.opacity(0.7))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .accessibilityElement(children: .combine)
    }

    var pixelSize: CGFloat {
        MessageMediaLayout.viewerPixelSize(screen: screenSize, displayScale: displayScale, declared: media.pixelSize)
    }

    func load(pixelSize: CGFloat) async {
        guard media.kind == .image, let url = URL(string: media.url) else {
            didFail = preview == nil
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
            didFail = preview == nil
        }
    }
}

private extension MessageMediaViewer {
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
        .padding(.top, 4)
    }
}
