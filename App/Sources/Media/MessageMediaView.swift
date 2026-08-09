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

    /// The row's tap arbitration, when this picture is inside a message row. It decides
    /// whether this tap was a single one — open the picture — or the first half of a double
    /// tap, which opens ``MediaActionsSheet`` instead and never opens the picture at all.
    /// `nil` on every other surface, where the picture opens at once.
    ///
    /// Read from the environment rather than passed down beside ``onTap`` because it travels
    /// through ``RichTextView``, which is shared with surfaces that inject neither. See
    /// ``MessageTapAction``.
    @Environment(\.messageTap) private var messageTap

    /// Who posted this picture and where, for the full-screen viewer's header. `nil` on a
    /// surface with no message behind the picture. See ``MessageMediaAttribution``.
    var attribution: MessageMediaAttribution?

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
    /// The picture two quick taps asked what to do with. See ``MediaActionsSheet``.
    @State private var acting: MediaActionsTarget?

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
        .accessibilityHint(hint)
        .accessibilityAddTraits(traits)
        .accessibilityActions { accessibilityActivation }
        .task(id: token) { await load(token) }
        .fullScreenCover(item: $viewing) { subject in
            MessageMediaViewer(subject: subject, loader: loader)
                // On the cover's root, not on anything inside it: a zoom transition
                // attached to a child of the presented content does not take.
                .navigationTransition(.zoom(sourceID: subject.id, in: zoom))
        }
        .sheet(item: $acting) { MediaActionsSheet(target: $0) }
    }

    /// Whether `source` is a subject that has already failed to load.
    ///
    /// Internal and pure so the rule can be exercised without a view host, exactly as
    /// ``RemoteImageDisplay/drawn(resolved:request:cached:)`` is. It is that same identity
    /// rule applied to the *absence* of a bitmap: `@State` survives a view whose inputs
    /// changed, so a row recycled onto another message would otherwise keep showing the
    /// previous message's failure notice over the new message's picture.
    ///
    /// A source that will not parse has failed before anything was attempted, which is why
    /// this answers rather than asking whether a load ran.
    nonisolated static func hasFailed(source: URL?, failed: URL?) -> Bool {
        guard let source else { return true }
        return failed == source
    }
}

// MARK: - Content

private extension MessageMediaView {
    @ViewBuilder
    var content: some View {
        switch media.kind {
        case .video:
            MessageMediaVideoPlaceholder(media: media)
        case .file:
            EmptyView()
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
            // A picture that fills its box covers the wash, so what a finger reads here is
            // the shrink: the tile pulls in and the frame's own fill shows around it. The
            // shape is named anyway, because the box a picture was fitted into rather than
            // filled is the case where the wash is the visible half — it lands in the
            // letterbox bands, and in the frame's corner rather than a squarer one.
            .buttonStyle(.hivePress(.control, in: MessageMediaFrame.shape))
            // A `Button` fires once for a pair of taps fast enough to be a double tap, so
            // the row can never count two of them here. This is the same gesture told to the
            // row directly. Simultaneous, so the button's own single tap is not made to wait
            // on it failing — the single is already deferred by the row, and once is enough.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { messageTap.reportDouble { act(on: image) } }
            )
        } else if hasFailed {
            if isRetryable {
                Button { retry() } label: {
                    MessageMediaFailureView(media: media)
                }
                // The same treatment as the picture it stands in for. A notice that answered
                // a press differently from the tile it replaced would be two vocabularies in
                // one box, and this one is a control for the same reason that one is.
                .buttonStyle(.hivePress(.control, in: MessageMediaFrame.shape))
            } else {
                // A URL this app cannot parse has nothing to try again, so the notice is
                // drawn without a control rather than with one that visibly does nothing.
                MessageMediaFailureView(media: media)
            }
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
                // The one route to the picture's actions that is not a double tap. A gesture
                // measured in the interval between two touches is not one VoiceOver offers,
                // so without this the sheet would exist and be unreachable — the actions
                // rotor is where a reader using it looks for exactly this.
                Button("Save or share image") { act(on: image) }
            }
        case (.image, .failed):
            if isRetryable {
                Button("Try again") { retry() }
            }
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
        MessageMediaView.hasFailed(source: sourceURL, failed: failedURL)
    }

    /// Whether a failure is worth offering a retry on.
    ///
    /// Everything that fails on the wire is: the media host on this deployment is
    /// tailnet-only, so walking out of range fails every attachment at once and walking
    /// back in fixes them. A URL that will not parse is the exception — there is nothing
    /// to try — and it is the reason this is a question rather than a constant.
    var isRetryable: Bool { sourceURL != nil }

    /// The hint, suppressed where the element is not actually interactive.
    var hint: String {
        if loadState == .failed, !isRetryable { return "" }
        return MessageMediaDescription.hint(for: media, state: loadState) ?? ""
    }

    var loadState: MessageMediaDescription.LoadState {
        if media.kind == .video || media.kind == .file { return .loaded }
        if displayedImage != nil { return .loaded }
        return hasFailed ? .failed : .loading
    }

    var traits: AccessibilityTraits {
        switch (media.kind, loadState) {
        case (.image, .loaded): [.isImage, .isButton]
        case (.image, .failed): isRetryable ? [.isButton] : []
        case (.image, .loading): [.isImage]
        // A placeholder for something that cannot be played is static text, and saying
        // "button" over it would promise an action there is not one of.
        case (.video, _), (.file, _): []
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

    /// Opens the viewer — through the row's arbitration, so a *second* tap arriving inside
    /// ``MessageTapArbiter/doubleTapWindow`` opens ``MediaActionsSheet`` instead and this
    /// never runs. The picture opens, or its actions open; never both.
    ///
    /// The claim above it is unchanged and still has to happen *now*, not with the opening:
    /// it is what stops the row's own tap counting this same touch a second time, and it is
    /// read one main-actor turn from now.
    func open(_ image: UIImage) {
        onTap?()
        messageTap.run(
            single: {
                viewing = MessageMediaViewerSubject(
                    media: [media],
                    startIndex: 0,
                    preview: image,
                    attribution: attribution
                )
            },
            double: { act(on: image) }
        )
    }

    /// Opens what a reader can do with this picture: keep it, or pass it on.
    ///
    /// The bitmap is handed over only as the share sheet's thumbnail — what is saved and what
    /// is shared is the *original*, fetched again. See ``MessageMediaExport``.
    ///
    /// Refused while the viewer is up, which is belt to ``MessageTapArbiter``'s braces. The
    /// arbiter is what should make this unreachable — a gesture answered as a single tap does
    /// not get to be answered again as a double — but a sheet presented over a
    /// `fullScreenCover` from the same view is a state SwiftUI has no defined answer for, and
    /// one line here is cheaper than trusting a timing argument with it.
    func act(on image: UIImage) {
        guard viewing == nil else { return }
        acting = MediaActionsTarget(media: media, preview: image)
    }

    /// A retry is arbitrated too, so a tap on an attachment is counted in one place whatever
    /// state it is in — but with no second meaning: a picture that never arrived has no bytes
    /// to save or to share, so two taps on the failure notice are two attempts at loading it,
    /// which is what a reader out of tailnet range is actually doing. With no `double` the
    /// arbiter does not defer at all, so the retry is immediate.
    func retry() {
        onTap?()
        messageTap.run(
            single: {
                failedURL = nil
                attempt += 1
            },
            double: nil
        )
    }
}
