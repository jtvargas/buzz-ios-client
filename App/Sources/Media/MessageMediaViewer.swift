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
    /// Who posted these pictures, when, and where — the viewer's header. `nil` on a
    /// surface with no message behind the picture, where the viewer draws no header
    /// rather than a header with holes in it. See ``MessageMediaAttribution``.
    var attribution: MessageMediaAttribution?

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
/// - **The header** is ``MessageMediaViewerHeader`` — the author's face, their name, the
///   hour, and the conversation the picture was posted in. It floats on the picture beside
///   the close button; see below.
/// - **Dismissal** is a `Done` button *and* the zoom transition's own interactive drag.
///   The button is the one that is certain — it is a control, it is reachable by
///   VoiceOver, and it works whatever a gesture recogniser underneath decides. The drag is
///   the one that feels right, and ``MessageMediaZoomView`` disables the scroll view's pan
///   at the fitted scale so that it can begin.
///
/// # Why the picture takes the whole screen and the chrome floats on it
///
/// Two layers, and they are told apart by which one ignores the safe area:
///
/// - **The picture ignores it.** It is fitted into the *whole screen* — a portrait
///   photograph gets the full height of the phone to be whole in, rather than the height
///   left over after a bar. This is the owner's own drawing: `image content behind`, with
///   the pill and the close button drawn over it.
/// - **The chrome respects it.** The pill and the button sit inside the safe area, so
///   nothing readable is ever under the clock, the Dynamic Island or the home indicator.
///
/// The earlier arrangement — the picture inset to clear a header declared as a
/// `safeAreaInset` — was rejected on sight: it spends the top of the screen on chrome at
/// the one moment the reader came here to look at a photograph, and a tall picture pays
/// for it twice, losing width to keep its shape.
///
/// What the chrome costs the picture is now *overlap* rather than *room*, and it is
/// bounded: the pill is one object in a corner, the picture behind it is still whole, and
/// a reader who wants the covered corner can pan it out from under with one finger.
///
/// # Where the bottom action bar goes
///
/// The owner deferred the row of actions Slack draws under a picture — share, save,
/// forward. When it arrives it joins the chrome layer as a second row, at the bottom of
/// the same safe-area-respecting stack; the picture behind it does not move, for the same
/// reason it does not move for the header.
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

    /// The accessibility identifier on each page's picture. See the use site.
    static let pictureIdentifier = "mediaViewerPicture"

    @State private var selection: Int
    @Environment(\.dismiss) private var dismiss

    init(subject: MessageMediaViewerSubject, loader: RemoteImageLoader = .messageMedia) {
        self.subject = subject
        self.loader = loader
        self._selection = State(initialValue: subject.startIndex)
    }

    var body: some View {
        // Two layers, told apart by which one ignores the safe area — and the reader is
        // deliberately *outside* the ignoring, because a `GeometryReader` that has
        // ignored the safe area reports its insets as **zero**. It is the only thing here
        // that still knows what they are, and the chrome's whole placement is that number.
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                pictures(screenSize: screen(in: proxy))
                chrome
                    .padding(.horizontal, 12)
                    .padding(.top, 4)
            }
        }
        .preferredColorScheme(.dark)
    }

    /// The whole screen, from a reader that was given the room inside the safe area.
    ///
    /// What the pixel size of each page's decode is derived from, so a picture is decoded
    /// for the screen it is actually drawn on rather than for the smaller rectangle this
    /// reader was proposed.
    private func screen(in proxy: GeometryProxy) -> CGSize {
        let insets = proxy.safeAreaInsets
        return CGSize(
            width: proxy.size.width + insets.leading + insets.trailing,
            height: proxy.size.height + insets.top + insets.bottom
        )
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
            // A `TabView` page is hosted inside a collection view cell, and that boundary
            // re-reads the window's safe area and applies it to the SwiftUI content in the
            // cell — an ancestor having already ignored it counts for nothing here. Without
            // this the cell is the full 874pt of a tall phone and the picture inside it is
            // 778, which is the picture stopping 96pt short of the screen it was supposed
            // to fill. Measured, and gated by ``MediaViewerLayoutTests``.
            .ignoresSafeArea()
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

private extension MessageMediaViewer {
    /// The pictures, filling the screen the chrome is drawn over.
    ///
    /// `screenSize` comes from the surface's own reader rather than a second one here: it
    /// is the expanded size, so the pixel size every page decodes to is the phone's whole
    /// screen and not the room left by a bar.
    func pictures(screenSize: CGSize) -> some View {
        TabView(selection: $selection) {
            // By position, for the same reason the mosaic is — the group can hold one URL
            // twice, and ``BuzzKit/MessageMedia/id`` is the URL. Here the consequence
            // would be a page the reader cannot reach: `.tag(index)` stays distinct while
            // the identity behind it does not.
            ForEach(Array(subject.media.enumerated()), id: \.offset) { index, media in
                MessageMediaViewerPage(
                    media: media,
                    preview: index == subject.startIndex ? subject.preview : nil,
                    screenSize: screenSize,
                    loader: loader
                )
                .tag(index)
            }
        }
        // Paging only earns its chrome once there is more than one page — a single
        // attachment's viewer must read exactly as it did before grouping existed, dots
        // and all.
        .tabViewStyle(.page(indexDisplayMode: subject.media.count > 1 ? .automatic : .never))
        .ignoresSafeArea()
    }

    /// The header pill and the close button, floating on the picture.
    ///
    /// One row at the top of the screen; the surface pushes it back down by the safe area
    /// the pictures behind it are ignoring, so nothing readable stands under the clock or
    /// the Dynamic Island.
    ///
    /// The pill takes its own width and no more — it is an object on the picture, not a
    /// bar across it — and the `Spacer` between the two is what makes a long name or a
    /// group DM's list of names truncate rather than push the close button off the screen.
    /// When there is no attribution the row is the button alone, which is what the viewer
    /// looked like before this existed.
    var chrome: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                if let attribution = subject.attribution {
                    MessageMediaViewerHeader(attribution: attribution)
                }
                Spacer(minLength: 0)
                doneButton
            }
        }
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
        // `.glass` is already the interactive material for a control — it lights under a
        // finger because a button is a thing that can be pressed. The pill beside it has
        // to ask for that appearance explicitly; see ``MessageMediaViewerHeader``.
        .buttonStyle(.glass)
        .accessibilityLabel("Done")
    }
}
