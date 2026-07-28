import SwiftUI
import UIKit

/// The mark at the leading edge of a link card: the site's own favicon when it can be
/// had, and a glyph for what the link *is* when it cannot.
///
/// # Why the favicon may arrive late and nothing moves
///
/// The slot is a fixed square, drawn from the first frame with the fallback glyph in it.
/// A favicon that lands two seconds later replaces the pixels inside that square and
/// changes no measurement anywhere — which is the same contract ``MessageMediaView``
/// keeps for a picture, and it is the reason a card can fetch anything at all. Nothing
/// else on the card is fetched: every word on it is derived from the URL (see
/// ``LinkPreview``).
///
/// # Why `/favicon.ico` and not an icon service
///
/// Because the alternative is worse in the way that matters. `google.com/s2/favicons`
/// and the equivalents at DuckDuckGo hand a third party the domain of every link anybody
/// in the workspace posts — a browsing record, assembled from a private relay, sent
/// somewhere nobody chose. Asking the origin for its own icon tells that origin, and only
/// that origin, that somebody read a message pointing at it, which is what following the
/// link would have told it anyway.
///
/// The cost is coverage: a site that declares its icon only in `<link rel="icon">` and
/// serves nothing at `/favicon.ico` gets the fallback glyph. That is a card that reads
/// slightly plainer, against a whole class of requests not made and an HTML parse not
/// written.
enum LinkPreviewIcon {
    /// The side of the icon's square, in points. Fixed, so the card's height does not
    /// depend on whether an icon was found.
    static let size: CGFloat = 20

    /// Where to ask a site for its icon, or `nil` when the URL has no host to ask.
    ///
    /// The host is used exactly as the link spells it, `www.` included — the stripped
    /// form on the card is for reading, and an apex that does not answer where the `www.`
    /// host does would fail for the sake of a cosmetic difference. The link's own scheme
    /// is kept for the same reason: this app talks to relays on plain `http` LANs, and a
    /// host reachable there over `http` may have no TLS at all.
    static func iconURL(for url: URL) -> URL? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), !host.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port
        components.path = "/favicon.ico"
        return components.url
    }

    /// The glyph drawn until — or instead of — the site's own icon.
    ///
    /// SF Symbols, so they inherit the card's colour and Dynamic Type; named per kind
    /// rather than one generic mark, because on the cards this app draws most often —
    /// a pull request from CI, a repository — the shape is the useful half of the card
    /// before any pixel arrives from the network.
    static func symbol(for kind: LinkPreview.Kind) -> String {
        switch kind {
        case .githubPullRequest: "arrow.triangle.pull"
        case .githubIssue, .linearIssue: "smallcircle.filled.circle"
        case .githubRepository: "book.closed"
        case .googleDriveFile: "doc"
        case .googleDriveFolder: "folder"
        case .googleDocument: "doc.text"
        case .googleSpreadsheet: "tablecells"
        case .googlePresentation: "rectangle.on.rectangle"
        case .web: "globe"
        }
    }
}

extension RemoteImageLoader {
    /// The loader favicons are drawn through: many tiny tiles that outlive a scroll.
    ///
    /// Sized between the two instances that already exist and for a different reason than
    /// either. A favicon decodes to 20 pt — smaller than an avatar — but it is keyed by
    /// *domain*, not by person, so one entry serves every card for that site in every
    /// channel, and a workspace talks about a handful of domains over and over. So: a
    /// generous count, and a budget that is a rounding error beside the attachment
    /// cache's 48 MB.
    ///
    /// Its own instance rather than sharing the avatar loader's for the reason set out
    /// there — a cost-bounded cache is only sound when the things in it are the same size
    /// class — and because a channel full of links should not be able to evict the faces
    /// of the people writing them.
    static let favicon = RemoteImageLoader(
        cache: RemoteImageCache(countLimit: 64, totalCostLimit: 2 * 1024 * 1024)
    )
}

/// The icon slot: the site's favicon once it is in hand, the kind's glyph until then.
struct LinkPreviewIconView: View {
    let preview: LinkPreview
    /// The loader to resolve the favicon through. Injectable so a test or a preview can
    /// supply its own cache and session.
    var loader: RemoteImageLoader = .favicon

    @State private var resolved: RemoteImageResolved?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image = displayedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: LinkPreviewIcon.symbol(for: preview.kind))
                    .font(.hiveSymbol(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        // Fixed before anything is fetched, so an icon arriving swaps pixels inside the
        // square and moves nothing. `.transaction` for the reason ``AvatarView`` clears
        // it: an ancestor's implicit animation would cross-fade that swap into a blink.
        .frame(width: LinkPreviewIcon.size, height: LinkPreviewIcon.size)
        .transaction { $0.animation = nil }
        .task(id: request) { await load() }
        .accessibilityHidden(true)
    }

    private var request: RemoteImageRequest {
        RemoteImageRequest(
            url: LinkPreviewIcon.iconURL(for: preview.url),
            pixelSize: LinkPreviewIcon.size * displayScale
        )
    }

    private var displayedImage: UIImage? {
        RemoteImageDisplay.drawn(resolved: resolved, request: request) { url, pixelSize in
            loader.cachedImage(for: url, pixelSize: pixelSize)
        }
    }

    private func load() async {
        guard let url = request.url else { return }
        let image = await loader.image(for: url, pixelSize: request.pixelSize)
        guard !Task.isCancelled, let image else { return }
        resolved = RemoteImageResolved(request: request, image: image)
    }
}
