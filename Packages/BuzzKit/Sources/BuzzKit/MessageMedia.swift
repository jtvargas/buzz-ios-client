import Foundation

/// What a piece of message media *is*, as far as anything that draws it is concerned.
///
/// The case exists before the renderer for it does. Video is carried through the whole
/// pipeline — parsed, classified, stored on the row — and simply not drawn yet, so
/// adding it later is a branch in one view rather than a change to the model, the
/// projection, and every test that reads them. A URL this cannot classify is not
/// media: it stays a link in the text, which is what it already was.
public enum MessageMediaKind: String, Sendable, Hashable, Codable {
    case image
    case video

    /// What a URL is, as far as anything that draws it is concerned, or `nil` when
    /// nothing here can say.
    ///
    /// The MIME type decides when there is one; the path extension decides otherwise.
    ///
    /// A declared `video/*` that is not one this app can play resolves to `nil` rather
    /// than falling through to the extension — the author said what it is, and guessing
    /// past that from a `.mp4` in the path would be second-guessing the tag.
    ///
    /// Public because classification is asked twice, and the second caller is not the
    /// `imeta` parse: a message's text can place a picture at a URL no tag describes,
    /// and the renderer has to know what to draw there. The two must agree, so there is
    /// one of these rather than an app-side copy of the extension list.
    public init?(url: String, mimeType: String? = nil) {
        if let mimeType {
            if mimeType.hasPrefix("image/") { self = .image; return }
            if mimeType.hasPrefix("video/") {
                guard mimeType == "video/mp4" else { return nil }
                self = .video
                return
            }
        }
        let path = (URL(string: url)?.path ?? url).lowercased()
        if path.hasSuffix(".mp4") { self = .video; return }
        let imageExtensions = [".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp"]
        guard imageExtensions.contains(where: path.hasSuffix) else { return nil }
        self = .image
    }
}

/// One attachment a message carries, as described by its own `imeta` tag (NIP-92).
///
/// # Why the dimensions matter more than they look
///
/// `dim` is the only thing here that is known *before* the bytes arrive, and the
/// conversation's scroll engine is the reason that is load-bearing. Rows live in a
/// `LazyVStack` whose content metrics are estimates, and a row that changes height
/// after it is on screen moves everything below it — which is exactly the reader's
/// place. An attachment whose aspect ratio is declared can reserve its space at layout
/// time and never resize; one without has to be given a fixed reservation instead,
/// because a picture that pushes the conversation when it finishes loading is worse
/// than one drawn in a box that was not quite its shape.
public struct MessageMedia: Sendable, Hashable, Codable, Identifiable {
    /// The attachment's own URL, which is also its identity: `imeta` is keyed by URL,
    /// and the same picture posted twice in one message is one attachment.
    public let url: String
    /// What to draw it as, resolved from the MIME type when the tag carries one and
    /// from the path extension otherwise.
    public let kind: MessageMediaKind
    /// The declared MIME type, when the tag carried one.
    public let mimeType: String?
    /// Width and height as authored, when the tag carried `dim`.
    public let pixelSize: CGSize?
    /// A still to draw in place of a video, from `image` or `thumb`. Unused while only
    /// images render; carried so the video case costs no model change.
    public let posterURL: String?
    /// The author's description, for VoiceOver and for the failure placeholder — a
    /// picture that will not load should still say what it was.
    public let alt: String?

    public var id: String { url }

    /// The aspect ratio to reserve space with, or `nil` when the tag did not declare
    /// usable dimensions. Guards the degenerate values as well as the missing ones: a
    /// zero or negative extent divides into an infinity or a negative height, and a
    /// frame built from either is a layout that never recovers.
    public var aspectRatio: CGFloat? {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        return pixelSize.width / pixelSize.height
    }

    public init(
        url: String,
        kind: MessageMediaKind,
        mimeType: String? = nil,
        pixelSize: CGSize? = nil,
        posterURL: String? = nil,
        alt: String? = nil
    ) {
        self.url = url
        self.kind = kind
        self.mimeType = mimeType
        self.pixelSize = pixelSize
        self.posterURL = posterURL
        self.alt = alt
    }
}

// MARK: - imeta

public extension MessageMedia {
    /// Every attachment an event declares, in the order its tags declare them.
    ///
    /// An `imeta` tag is a list of `"key value"` strings rather than a list of pairs
    /// (NIP-92), so each entry is split on its *first* space only — a value may contain
    /// spaces, and `alt` routinely does.
    ///
    /// A tag with no `url`, or one this cannot classify, is dropped rather than carried
    /// as an unknown: the URL is still in the message text, where it renders as a link.
    /// Dropping it here means "not media", not "lost".
    static func parse(tags: [[String]]) -> [MessageMedia] {
        var seen = Set<String>()
        var media: [MessageMedia] = []

        for tag in tags where tag.first == "imeta" {
            var fields: [String: String] = [:]
            for part in tag.dropFirst() {
                guard let separator = part.firstIndex(of: " "), separator > part.startIndex else { continue }
                let key = String(part[part.startIndex ..< separator])
                let value = String(part[part.index(after: separator)...])
                // First wins: a tag that repeats a key is malformed, and taking the
                // first keeps the result a function of the tag rather than of its order.
                if fields[key] == nil { fields[key] = value }
            }

            guard let url = fields["url"], !url.isEmpty, !seen.contains(url) else { continue }
            guard let kind = MessageMediaKind(url: url, mimeType: fields["m"]) else { continue }
            seen.insert(url)

            media.append(
                MessageMedia(
                    url: url,
                    kind: kind,
                    mimeType: fields["m"],
                    pixelSize: pixelSize(fields["dim"]),
                    posterURL: fields["image"] ?? fields["thumb"],
                    alt: fields["alt"]
                )
            )
        }
        return media
    }

    /// `WIDTHxHEIGHT`, and nothing else. Anything that does not parse cleanly into two
    /// finite numbers yields `nil` rather than a partial size.
    private static func pixelSize(_ dim: String?) -> CGSize? {
        guard let parts = dim?.split(separator: "x", omittingEmptySubsequences: false), parts.count == 2,
              let width = Double(parts[0]), let height = Double(parts[1]),
              width.isFinite, height.isFinite
        else { return nil }
        return CGSize(width: width, height: height)
    }
}
