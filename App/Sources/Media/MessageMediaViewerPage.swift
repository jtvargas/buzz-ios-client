import BuzzKit
import SwiftUI
import UIKit

/// One picture of the gallery, full screen. Its own load and its own failure notice,
/// because each page decodes a different source at whatever pixel size the shared screen
/// geometry implies for *its* declared dimensions — the one thing neighbouring pages
/// cannot answer for each other.
struct MessageMediaViewerPage: View {
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
            // The page is given an exact screen's worth by the scroll view above, so this
            // fills that and nothing declines a safe area here. It did when the pager was
            // a `TabView`: a page there is hosted in a collection view cell, and that
            // boundary re-reads the window's safe area and applies it to the SwiftUI
            // content inside, which left the cell 874pt tall on a tall phone and the
            // picture in it 778. Gated either way by ``MediaViewerLayoutTests``.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Keyed by the pixel size rather than by the geometry: the target is derived
            // from the screen's *longest* edge, so a rotation cannot change it and cannot
            // re-run a decode that would produce the identical bitmap.
            .task(id: pixelSize) {
                await load(pixelSize: pixelSize)
            }
    }
}

extension MessageMediaViewerPage {
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
                // Named apart from the inline picture, which carries the same label — the
                // author's `alt` — and is still in the hierarchy behind the cover. The
                // rectangle this reports is the *page*, which is what says whether the
                // picture layer takes the whole screen or stops at a bar.
                .accessibilityIdentifier(MessageMediaViewer.pictureIdentifier)
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
