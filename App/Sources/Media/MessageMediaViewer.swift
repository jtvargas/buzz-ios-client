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

    /// Which page the scroll view is resting on, by position in ``MessageMediaViewerSubject/media``.
    ///
    /// Optional because that is what `scrollPosition(id:)` binds to — `nil` means the
    /// scroll view is between pages, which a paging behaviour only passes through.
    @State private var page: Int?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale

    init(subject: MessageMediaViewerSubject, loader: RemoteImageLoader = .messageMedia) {
        self.subject = subject
        self.loader = loader
        // Deliberately not seeded with `startIndex`: a `scrollPosition` set before the
        // first layout is not honoured, and seeding it makes the dots claim a page the
        // scroll view is not on. The opening page is placed by `ScrollViewReader`; this
        // binding only ever *reports* where the reader has got to. Until it does, every
        // use of it falls back to `startIndex`, which is where the scroll view is going.
        self._page = State(initialValue: nil)
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
                pageDots
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 8)
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

private extension MessageMediaViewer {
    /// The pictures, filling the screen the chrome is drawn over.
    ///
    /// `screenSize` comes from the surface's own reader rather than a second one here: it
    /// is the expanded size, so the pixel size every page decodes to is the phone's whole
    /// screen and not the room left by a bar.
    func pictures(screenSize: CGSize) -> some View {
        ScrollViewReader { reader in
            pages(screenSize: screenSize)
                // A `scrollPosition` seeded before the first layout is NOT honoured: the
                // scroll view rested on the first page while the binding — and so the dots
                // — said the second, which is a gallery opening on a picture the reader did
                // not tap. Measured on the second cell of a two-picture message, and the
                // reason ``MediaViewerLayoutTests`` now asks *where* the page is and not
                // merely whether it exists. `ScrollViewReader` is the mechanism that does
                // work against a lazy stack, and is what the message list here uses for the
                // same reason.
                .onAppear { reader.scrollTo(subject.startIndex, anchor: .center) }
        }
    }

    func pages(screenSize: CGSize) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                // By position, for the same reason the mosaic is — the group can hold one
                // URL twice, and ``BuzzKit/MessageMedia/id`` is the URL. Here the
                // consequence would be a page the reader cannot reach: the offset stays
                // distinct while the identity behind it does not.
                ForEach(Array(subject.media.enumerated()), id: \.offset) { index, media in
                    MessageMediaViewerPage(
                        media: media,
                        preview: index == subject.startIndex ? subject.preview : nil,
                        screenSize: screenSize,
                        loader: loader
                    )
                    // Exactly one screen, which is what makes the paging land on a picture
                    // rather than between two.
                    .frame(width: screenSize.width, height: screenSize.height)
                    .id(index)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $page)
        .scrollIndicators(.hidden)
        // A gallery of one is not a gallery: with nothing to page to, the horizontal drag
        // belongs to the presentation's interactive dismissal, exactly as the zoom view
        // hands it over at the fitted scale.
        .scrollDisabled(subject.media.count <= 1)
        .ignoresSafeArea()
        // The neighbours are decoded before the reader arrives at them. A `LazyHStack`
        // builds a page as it comes into reach, so without this the decode starts *during*
        // the swipe and the page lands as a spinner that becomes a picture.
        .task(id: page) { await prefetchNeighbours(of: page ?? subject.startIndex, screenSize: screenSize) }
    }

    /// Warms the loader's cache for the pages either side of `index`.
    ///
    /// Nothing is kept: the point is that the page's own load finds the picture already
    /// decoded and can show it without suspending.
    func prefetchNeighbours(of index: Int, screenSize: CGSize) async {
        for neighbour in [index - 1, index + 1] {
            guard subject.media.indices.contains(neighbour) else { continue }
            let media = subject.media[neighbour]
            guard media.kind == .image, let url = URL(string: media.url) else { continue }
            _ = await loader.image(
                for: url,
                pixelSize: MessageMediaLayout.viewerPixelSize(
                    screen: screenSize,
                    displayScale: displayScale,
                    declared: media.pixelSize
                )
            )
            if Task.isCancelled { return }
        }
    }

    /// Which page of a gallery the reader is on. Drawn rather than taken from the paging
    /// container, which no longer has any: `.scrollTargetBehavior(.paging)` is a scroll
    /// view's own crisp snap and comes with no chrome of its own.
    ///
    /// Sits above the home indicator because the whole chrome layer does — it is inside
    /// the safe area, and the pictures behind it are not.
    @ViewBuilder
    var pageDots: some View {
        if subject.media.count > 1 {
            HStack(spacing: 7) {
                ForEach(subject.media.indices, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == (page ?? subject.startIndex) ? 1 : 0.4))
                        .frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            // The same material as the pill, for the same reason: a white dot on a white
            // photograph is not a dot.
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Page \((page ?? subject.startIndex) + 1) of \(subject.media.count)")
        }
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
            // Centred on each other, not on their tops: the pill is two lines of text and
            // the button is a circle, so aligning their tops leaves the circle riding high
            // above the name it sits beside.
            HStack(alignment: .center, spacing: 8) {
                if let attribution = subject.attribution {
                    MessageMediaViewerHeader(attribution: attribution)
                }
                Spacer(minLength: 0)
                closeButton
            }
        }
    }

    /// The system's own close button: a glass circle carrying the standard `xmark`.
    ///
    /// Three parts, and each replaces something that was wrong:
    ///
    /// - **`role: .close`** is iOS 26's dismissal semantic. Its *default* label is the word
    ///   `Close`, which is right in a sheet's toolbar and wrong floating on a photograph,
    ///   so the label is the standard glyph and the role carries the meaning.
    /// - **`.buttonBorderShape(.circle)`** is what makes it round. The first build asked
    ///   for a 44pt minimum frame on the glyph instead, and the glass style's own padding
    ///   turned that into a 68x58 **oval** — which is what read as weird.
    /// - **`.tint(.primary)`** takes the app's amber accent off it. Every control inherits
    ///   that accent by default; nowhere else on the phone is a close button the app's
    ///   brand colour.
    ///
    /// And the **size**, which is the third thing the owner sent it back for. Left to size
    /// itself around a bare glyph the circle came out at **30pt**, which does not read as
    /// one of the phone's own controls beside a 44pt back button. The glass style adds a
    /// measured ~14pt around whatever it is given, so the *label* is sized and the circle
    /// follows: 30 + 14 = 44. That arithmetic is empirical and would not survive a change
    /// in the style's padding, which is exactly why ``MediaViewerLayoutTests`` measures the
    /// button on a real screen rather than trusting it.
    ///
    /// It is centred on the pill beside it rather than aligned to its top; see ``chrome``.
    var closeButton: some View {
        Button(role: .close) {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.hiveSymbol(.body, weight: .semibold))
                .frame(width: 30, height: 30)
        }
        // `.glass` is already the interactive material for a control — it lights under a
        // finger because a button is a thing that can be pressed. The pill beside it has
        // to ask for that appearance explicitly; see ``MessageMediaViewerHeader``.
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .tint(.primary)
        .accessibilityLabel("Done")
    }
}
