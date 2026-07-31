import BuzzKit
import SwiftUI
import UIKit

/// A message's consecutive pictures, drawn as one attachment: a single frame for one
/// picture, a mosaic for more than one — see ``MessageMediaMosaicLayout``.
///
/// # Why this exists rather than ``RichTextView`` calling ``MessageMediaView`` in a loop
///
/// A mosaic is one tap target with one shared zoom transition into a gallery the reader
/// swipes across, not several independent attachments that happen to sit next to each
/// other. Deciding that shape — one cell each, or the single reserved box this app has
/// always drawn — has to happen above any individual picture, which is what this view is
/// for.
///
/// The single-picture path is not reimplemented here: for one item this delegates
/// straight to ``MessageMediaView``, so the common case is byte-identical to what shipped
/// before grouping existed.
struct MessageMediaGroupView: View {
    /// The pictures this attachment groups, in reading order. Never empty in practice —
    /// ``RichTextMedia/lift(_:describedBy:)`` never produces an empty group — but a
    /// defensive empty case draws nothing rather than crashing on a malformed message.
    let media: [MessageMedia]

    /// The row's tap claim — see ``MessageMediaView/onTap``. Forwarded unchanged to
    /// whichever path handles the tap.
    var onTap: (() -> Void)?

    /// Who posted these pictures and where, for the full-screen viewer's header.
    /// Forwarded unchanged, exactly like the tap claim. See ``MessageMediaAttribution``.
    var attribution: MessageMediaAttribution?

    var loader: RemoteImageLoader = .messageMedia

    var body: some View {
        if media.count > 1 {
            MessageMediaMosaicView(media: media, onTap: onTap, attribution: attribution, loader: loader)
        } else if let only = media.first {
            MessageMediaView(media: only, onTap: onTap, attribution: attribution, loader: loader)
        }
    }
}

// MARK: - The mosaic

/// More than one picture, laid out in ``MessageMediaMosaicLayout``'s grid and opened as a
/// gallery the reader pages across.
///
/// One namespace shared by every cell, matching the single-picture path's own
/// ``MessageMediaView/zoom``: the zoom transition needs a source and a destination
/// registered in the same namespace, and a cell's ``MessageMedia/url`` is already the id
/// both sides key on, so distinct cells under one shared namespace never collide.
private struct MessageMediaMosaicView: View {
    let media: [MessageMedia]
    var onTap: (() -> Void)?
    var attribution: MessageMediaAttribution?
    var loader: RemoteImageLoader

    @State private var viewing: MessageMediaViewerSubject?
    @Namespace private var zoom

    var body: some View {
        MessageMediaMosaicReservation(count: media.count) {
            // Identified by position, not by ``BuzzKit/MessageMedia/id`` — which is the
            // URL, and a group can hold the same URL twice. `![](u) ![](u)` is ordinary
            // markdown, and `RichTextMedia.split` emits one block per image *run* rather
            // than per distinct URL, so the fold produces two entries with equal ids.
            // A `ForEach` over duplicate ids is undefined by SwiftUI's own diagnostic,
            // while the reservation above has already committed to `media.count` cells.
            // Position is stable here for the reason it usually is not: the array is
            // fixed for the life of one rendered message.
            ForEach(Array(media.enumerated()), id: \.offset) { index, item in
                MessageMediaMosaicCellView(media: item, position: index, onOpen: { image in
                    onTap?()
                    viewing = MessageMediaViewerSubject(
                        media: media,
                        startIndex: index,
                        preview: image,
                        attribution: attribution
                    )
                }, loader: loader)
                .matchedTransitionSource(id: item.url, in: zoom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: MessageMediaMosaicLayout.cornerRadius, style: .continuous))
        // `.contain`, not `.combine`: the row above this already combines everything it
        // draws into one utterance (see ``MessageMediaView``'s note on that), and each
        // cell's own `.accessibilityActions` is what has to survive that flattening.
        // Combining here first would merge three labels into one before the row ever
        // gets to, and the per-picture "View image N" actions below exist precisely so
        // three pictures in one block stay three reachable actions rather than one.
        .accessibilityElement(children: .contain)
        .fullScreenCover(item: $viewing) { subject in
            MessageMediaViewer(subject: subject, loader: loader)
                .navigationTransition(.zoom(sourceID: subject.id, in: zoom))
        }
    }
}

/// One picture inside a mosaic: its own load, its own failure notice, its own tap.
///
/// Deliberately not a reuse of ``MessageMediaView``'s body. The two answer different
/// questions about the same bytes: a lone attachment reserves *its own* shape and
/// letterboxes when it does not know it (``MessageMediaLayout/Box/isExact``), where a
/// mosaic cell is handed a fixed rectangle by ``MessageMediaMosaicReservation`` before any
/// picture in the group has a shape of its own, and fills it — a grid of tiles reads as
/// one set exactly because none of them is shaped like its own picture. The loading,
/// failure and retry machinery below is the same rule applied to a different box, kept
/// separate rather than parameterising one view for both, since the box is the one thing
/// neither view can hand the other without re-deriving it.
private struct MessageMediaMosaicCellView: View {
    let media: MessageMedia
    /// This cell's position in the group, folded into its custom action's label —
    /// see the mosaic's note on why the label has to stay distinct once three of these
    /// are merged into one row utterance.
    let position: Int
    /// Called with the bitmap on screen when the reader activates this cell — by tap or
    /// by its accessibility action — so the mosaic can open the gallery on the right page
    /// with a preview already in hand, exactly as ``MessageMediaView/open(_:)`` does for
    /// one picture.
    let onOpen: (UIImage?) -> Void
    var loader: RemoteImageLoader = .messageMedia

    @State private var resolved: RemoteImageResolved?
    @State private var failedURL: URL?
    @State private var attempt = 0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            Rectangle().fill(MessageMediaFrame.fill)
            content
        }
        .clipped()
        // Same reasoning as `MessageMediaView`: a picture landing must replace pixels,
        // not cross-fade, or a mosaic filling in over a couple of frames reads as a
        // flicker instead of a load.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MessageMediaDescription.label(for: media, state: loadState))
        .accessibilityValue(MessageMediaDescription.value(for: media) ?? "")
        .accessibilityHint(hint)
        .accessibilityAddTraits(traits)
        .accessibilityActions { accessibilityActivation }
        .task(id: token) { await load(token) }
    }
}

// MARK: - Content

private extension MessageMediaMosaicCellView {
    @ViewBuilder
    var content: some View {
        switch media.kind {
        case .video:
            MessageMediaVideoPlaceholder(media: media)
        case .image:
            imageContent
        }
    }

    @ViewBuilder
    var imageContent: some View {
        if let image = displayedImage {
            Button { onOpen(image) } label: {
                // A grid tile fills and crops rather than letterboxing — the shape that
                // reads as one coherent set. `Color.clear.overlay` is still what makes
                // the whole cell the tap target and not just the pixels the image
                // happens to cover, matching ``MessageMediaView``'s own construction.
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            // A plain rectangle, not the shared corner radius: a cell's own edges are
            // straight, and the one rounded corner four of them have belongs to the mosaic's
            // clip rather than to the cell. A rounded wash inside a square tile is the
            // mismatch that is more visible than no wash at all.
            .buttonStyle(.hivePress(.control, in: .rect))
        } else if hasFailed {
            if isRetryable {
                Button { retry() } label: {
                    MessageMediaFailureView(media: media)
                }
                // The cell's own treatment, in the cell's own square shape — see above.
                .buttonStyle(.hivePress(.control, in: .rect))
            } else {
                MessageMediaFailureView(media: media)
            }
        } else {
            MessageMediaLoadingView()
        }
    }

    @ViewBuilder
    var accessibilityActivation: some View {
        switch (media.kind, loadState) {
        case (.image, .loaded):
            if let image = displayedImage {
                Button("View image \(position + 1)") { onOpen(image) }
            }
        case (.image, .failed):
            if isRetryable {
                Button("Try image \(position + 1) again") { retry() }
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - State

private extension MessageMediaMosaicCellView {
    var sourceURL: URL? { URL(string: media.url) }

    struct Token: Equatable {
        let request: RemoteImageRequest
        let attempt: Int
    }

    var token: Token {
        Token(
            request: RemoteImageRequest(
                url: sourceURL,
                pixelSize: MessageMediaLayout.inlinePixelSize(displayScale: displayScale)
            ),
            attempt: attempt
        )
    }

    var displayedImage: UIImage? {
        guard media.kind == .image else { return nil }
        return RemoteImageDisplay.drawn(resolved: resolved, request: token.request) { url, pixelSize in
            loader.cachedImage(for: url, pixelSize: pixelSize)
        }
    }

    var hasFailed: Bool { MessageMediaView.hasFailed(source: sourceURL, failed: failedURL) }
    var isRetryable: Bool { sourceURL != nil }

    var hint: String {
        if loadState == .failed, !isRetryable { return "" }
        return MessageMediaDescription.hint(for: media, state: loadState) ?? ""
    }

    var loadState: MessageMediaDescription.LoadState {
        if media.kind == .video { return .loaded }
        if displayedImage != nil { return .loaded }
        return hasFailed ? .failed : .loading
    }

    var traits: AccessibilityTraits {
        switch (media.kind, loadState) {
        case (.image, .loaded): [.isImage, .isButton]
        case (.image, .failed): isRetryable ? [.isButton] : []
        case (.image, .loading): [.isImage]
        case (.video, _): []
        }
    }
}

// MARK: - Loading

private extension MessageMediaMosaicCellView {
    func load(_ token: Token) async {
        guard media.kind == .image, let url = token.request.url else { return }
        if token.attempt > 0 { await loader.retryFailures() }
        let image = await loader.image(for: url, pixelSize: token.request.pixelSize)
        guard !Task.isCancelled else { return }

        if let image {
            resolved = RemoteImageResolved(request: token.request, image: image)
            if failedURL != nil { failedURL = nil }
        } else if failedURL != url {
            failedURL = url
        }
    }

    func retry() {
        failedURL = nil
        attempt += 1
    }
}
