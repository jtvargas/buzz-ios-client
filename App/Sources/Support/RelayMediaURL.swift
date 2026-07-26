import CoreGraphics
import Foundation

/// The relay's Blossom media URL shape, and the thumbnail variant it publishes beside
/// every image it stores.
///
/// # Why bother
///
/// Agent avatars on this relay are full-resolution PNGs: measured live, `1254×1254` at
/// 593–838 KB, every byte of which the client downloads before ImageIO throws all but a
/// 36-pt tile away. The relay's own uploader already generates a thumbnail for each blob
/// (`buzz-media/src/thumbnail.rs`) and serves it at a derivable URL, at 9–16 KB. For an
/// avatar that is a ~60× saving in transfer and a proportional saving in decode, with no
/// visible difference at any size the app actually draws.
enum RelayMediaURL {
    /// The longest edge, in pixels, of the relay's generated thumbnail.
    ///
    /// Fixed by the relay's encoder, which calls `image::thumbnail(320, 320)` and writes
    /// JPEG. Aspect ratio is preserved, so this is the same "longest edge" quantity
    /// ``AvatarLoader/downsample(_:maxPixelSize:)`` asks ImageIO for, and a request at or
    /// below it is a downsample rather than an upscale. Every avatar the app draws today
    /// fits: the largest is the 96-pt profile header, 288 px on a 3× screen.
    static let thumbnailMaximumPixelSize: CGFloat = 320

    /// The thumbnail URL for `url`, or `nil` when `url` is not a relay media URL.
    ///
    /// The shape matched is `<scheme>://<host>/…/media/<64-hex>.<ext>`, rewritten to
    /// `…/media/<64-hex>.thumb.jpg`. Query and fragment are carried across untouched in
    /// case a deployment ever signs these URLs.
    ///
    /// Requiring the extension to contain no further `.` is what stops a thumbnail URL
    /// from matching itself: the stem of `<hex>.thumb.jpg` is `<hex>.thumb`, which is not
    /// 64 hex characters, so there is no `…thumb.thumb.jpg` to derive.
    static func thumbnail(for url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }

        let path = components.path
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let directory = path[path.startIndex ..< slash]
        let file = path[path.index(after: slash)...]
        guard directory.hasSuffix("/media") else { return nil }

        guard let dot = file.firstIndex(of: ".") else { return nil }
        let digest = file[file.startIndex ..< dot]
        let extensionName = file[file.index(after: dot)...]
        guard digest.count == 64,
              digest.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              !extensionName.isEmpty,
              !extensionName.contains(".")
        else { return nil }

        components.path = "\(directory)/\(digest).thumb.jpg"
        return components.url
    }

    /// The thumbnail URL to fetch instead of `url` for a request at `pixelSize`, or
    /// `nil` when the original should be fetched — either because `url` is not relay
    /// media, or because the request is larger than the thumbnail and using it would
    /// mean upscaling a 320-px source.
    static func thumbnail(for url: URL, pixelSize: CGFloat) -> URL? {
        guard pixelSize.isFinite, pixelSize <= thumbnailMaximumPixelSize else { return nil }
        return thumbnail(for: url)
    }
}
