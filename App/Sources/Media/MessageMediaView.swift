import BuzzKit
import SwiftUI
import UIKit

/// One attachment, drawn inline under the message that carries it.
///
/// # The requirement this exists to meet
///
/// **The conversation must not move.** A message list is a `LazyVStack` whose off-screen
/// content is estimated, so a row that settles at a different height once its picture
/// arrives displaces every row below it — and while a reader is reading, that is their
/// place in the conversation being taken away. So the box is decided from the `imeta`
/// tag before a single byte is fetched (``MessageMediaReservation``), and *nothing that
/// happens afterwards changes it*: the loading state, the picture, and the failure notice
/// are three different fills of one rectangle that was measured before anyone knew which
/// of them it would be.
///
/// That holds in both halves of the problem, and they are genuinely different:
///
/// - **`dim` was declared.** The box is the picture's own shape, capped, so the picture
///   fills it exactly and there is nothing to letterbox.
/// - **`dim` was missing.** There is nothing to derive a shape from, so a 4:3 box is
///   reserved and the picture is *fitted* inside it when it arrives — centred, on the
///   frame's own fill, at whatever shape it turns out to be. Upstream instead lets the
///   loaded bytes size the widget, which is where the jump comes from. Letterboxing is the
///   visible cost of an author who did not send `dim`; it is much cheaper than the
///   alternative, and a tap shows the picture properly.
///
/// # What it reuses
///
/// The whole image pipeline. ``RemoteImageLoader`` downsamples with ImageIO to the pixel
/// size the box needs, off the main thread, de-duplicates concurrent asks for the same
/// artwork, and remembers failures so a row scrolling in and out cannot turn one 404 into
/// a request per pass. ``RemoteImageDisplay`` decides which bitmap in hand belongs on
/// screen this frame. Both are the avatar pipeline, generalised rather than copied — a
/// second image path in one app is two sets of scroll-performance bugs.
///
/// The one thing it does not share is the *cache*, deliberately: see
/// ``RemoteImageLoader/messageMedia``.
///
/// # A note for whatever renders this
///
/// If this lands inside an element that has been flattened with
/// `.accessibilityElement(children: .combine)` — which a message row is — its label is
/// merged into that row's single utterance, which is right, but its button is swallowed.
/// The custom action below is what survives the flattening, and it is why there is one.
struct MessageMediaView: View {
    /// The attachment to draw.
    let media: MessageMedia

    /// Called first for every tap this view handles — opening the viewer, or retrying a
    /// load that failed.
    ///
    /// It exists for the surface's benefit, not this view's. A message row arbitrates
    /// taps: its own `onTapGesture` opens the thread on the next main-actor turn unless
    /// something claimed the tap first, exactly as the reaction chips and the reply
    /// preview do. A row rendering this should pass its `claimTap`, or a tap on a picture
    /// also pushes the thread behind it.
    var onTap: (() -> Void)?

    /// The loader to resolve artwork through. Defaults to the attachment-sized instance;
    /// injectable so a test or a preview can supply its own cache and session.
    var loader: RemoteImageLoader = .messageMedia

    @State private var resolved: RemoteImageResolved?
    /// The source that produced no image, so a recycled row cannot inherit the previous
    /// message's failure — the same identity rule ``RemoteImageDisplay`` applies to the
    /// bitmap, applied to the absence of one.
    @State private var failedURL: URL?
    /// How many times the reader has asked for this to be tried again. Part of the load's
    /// identity, so a retry restarts the task that a plain state change would not.
    @State private var attempt = 0
    @State private var viewing: MessageMediaViewerSubject?

    @Environment(\.displayScale) private var displayScale
    @Namespace private var zoom

    var body: some View {
        MessageMediaReservation(aspectRatio: media.aspectRatio, kind: media.kind) {
            ZStack {
                // Drawn under every state, so the box is a surface from the first frame
                // rather than a hole that becomes a picture.
                Rectangle().fill(MessageMediaFrame.fill)
                content
            }
            // The box is fixed independently of what is in it, so a picture arriving
            // replaces pixels without moving anything. Letting an ancestor's implicit
            // animation — a list insert, a sheet presentation — cross-fade that
            // replacement is the one way it reads as a flicker rather than as a load.
            .transaction { $0.animation = nil }
        }
        .clipShape(MessageMediaFrame.shape)
        .overlay {
            MessageMediaFrame.shape.strokeBorder(MessageMediaFrame.border, lineWidth: 1)
        }
        .matchedTransitionSource(id: media.url, in: zoom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MessageMediaDescription.label(for: media, state: loadState))
        .accessibilityValue(MessageMediaDescription.value(for: media) ?? "")
        .accessibilityHint(MessageMediaDescription.hint(for: media, state: loadState) ?? "")
        .accessibilityAddTraits(traits)
        .accessibilityActions { accessibilityActivation }
        .task(id: token) { await load(token) }
        .fullScreenCover(item: $viewing) { subject in
            MessageMediaViewer(subject: subject, loader: loader)
                // On the cover's root, not on anything inside it: a zoom transition
                // attached to a child of the presented content does not take.
                .navigationTransition(.zoom(sourceID: subject.id, in: zoom))
        }
    }
}

// MARK: - Content

private extension MessageMediaView {
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
            Button { open(image) } label: {
                // `Color.clear` takes exactly the size it is proposed and an overlay never
                // changes the size of what it overlays, so this pair is the construction
                // that guarantees the button is the reserved box whatever shape the
                // picture turned out to be. A `.fill` picture overflows it and is clipped
                // by the frame; a `.fit` one is centred inside it.
                Color.clear.overlay {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: MessageMediaLayout.contentMode(for: media))
                }
            }
            .buttonStyle(.plain)
        } else if hasFailed {
            Button { retry() } label: {
                MessageMediaFailureView(media: media)
            }
            .buttonStyle(.plain)
        } else {
            MessageMediaLoadingView()
        }
    }

    /// The rotor action that survives being folded into a message row's combined element.
    @ViewBuilder
    var accessibilityActivation: some View {
        switch (media.kind, loadState) {
        case (.image, .loaded):
            if let image = displayedImage {
                Button("View image") { open(image) }
            }
        case (.image, .failed):
            Button("Try again") { retry() }
        default:
            EmptyView()
        }
    }
}

// MARK: - State

private extension MessageMediaView {
    /// The attachment's source, or `nil` for a URL string this app cannot parse — which is
    /// a failure, and is drawn as one rather than as a box that loads for ever.
    var sourceURL: URL? { URL(string: media.url) }

    /// The identity of one load. A change in the source, in the pixel size, or in the
    /// retry count restarts the task; nothing else does.
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

    var hasFailed: Bool {
        // An unparseable URL has already failed and has nothing to attempt, so it is
        // reported as such rather than compared against a source that does not exist.
        guard let sourceURL else { return true }
        return failedURL == sourceURL
    }

    var loadState: MessageMediaDescription.LoadState {
        if media.kind == .video { return .loaded }
        if displayedImage != nil { return .loaded }
        return hasFailed ? .failed : .loading
    }

    var traits: AccessibilityTraits {
        switch (media.kind, loadState) {
        case (.image, .loaded): [.isImage, .isButton]
        case (.image, .failed): [.isButton]
        case (.image, .loading): [.isImage]
        // A placeholder for something that cannot be played is static text, and saying
        // "button" over it would promise an action there is not one of.
        case (.video, _): []
        }
    }
}

// MARK: - Loading

private extension MessageMediaView {
    func load(_ token: Token) async {
        guard media.kind == .image, let url = token.request.url else { return }
        // A retry is only a real retry once the loader has forgotten why it stopped
        // asking. Clearing here rather than in the button's action is what orders the two:
        // the task restarts on the attempt count, and it must not reach `image(for:)`
        // before the suppression it is trying to get past has gone.
        if token.attempt > 0 { await loader.retryFailures() }

        let image = await loader.image(for: url, pixelSize: token.request.pixelSize)
        // `.task(id:)` was cancelled if this view moved on to another attachment; the
        // identity carried in `resolved` is the belt to this braces, covering the frame
        // between the inputs changing and the task restarting.
        guard !Task.isCancelled else { return }

        if let image {
            resolved = RemoteImageResolved(request: token.request, image: image)
            // Guarded because `@State` invalidates on assignment whether or not the value
            // changed, and this runs for every attachment that ever succeeds.
            if failedURL != nil { failedURL = nil }
        } else if failedURL != url {
            failedURL = url
        }
    }

    func open(_ image: UIImage) {
        onTap?()
        viewing = MessageMediaViewerSubject(media: media, preview: image)
    }

    func retry() {
        onTap?()
        failedURL = nil
        attempt += 1
    }
}
