import CryptoKit
import ImageIO
import UIKit

/// Loads, downsamples, caches, and de-duplicates avatar image requests.
///
/// An actor so the caches and the in-flight table are mutated without a lock, and so a
/// burst of rows asking for the same artwork while scrolling shares one fetch and one
/// decode rather than starting a request each.
///
/// The actor is only a *coordinator*. The two expensive things happen off it:
///
/// - Fetch and decode run in ``fetch(_:thumbnail:pixelSize:session:)``, a `nonisolated`
///   `async` function, so Swift hops it to the concurrent executor (SE-0338) instead of
///   holding this actor for the length of a network round trip and an ImageIO decode.
/// - Cache *hits* never reach the actor at all — see ``cachedImage(for:pixelSize:)``.
actor AvatarLoader {
    static let shared = AvatarLoader()

    /// Decoded images, keyed by source identity and target pixel size.
    ///
    /// A `nonisolated let` over a thread-safe cache rather than actor state, so the main
    /// actor can peek synchronously while rendering. That peek is the difference between a
    /// row scrolling back in showing its picture immediately and showing one frame of
    /// monogram first, because `.task` runs *after* the frame it was attached to.
    private nonisolated let cache: AvatarImageCache
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var failures = AvatarFailureCache()
    private let session: URLSession

    init(session: URLSession = AvatarLoader.makeSession(), cache: AvatarImageCache = AvatarImageCache()) {
        self.session = session
        self.cache = cache
    }

    /// The session avatars are fetched on.
    ///
    /// `URLCache.shared` is left in place — the relay serves media as
    /// `cache-control: public, max-age=31536000, immutable`, so the URL loading system
    /// already collapses the repeat fetches that keying the image cache by pixel size
    /// implies (a 30-pt mention, a 34-pt row, and a 36-pt timeline avatar are three cache
    /// entries but one download), and a 12 KB thumbnail persists across launches for free.
    ///
    /// The one change from the default is the *idle* timeout, cut from 60 seconds to 15.
    /// The media host is tailnet-only, so off the tailnet every request fails; failing in
    /// fifteen seconds rather than sixty is the difference between a screen of rows parking
    /// a task each for a minute and doing so for a quarter of one. Deliberately the idle
    /// timeout and not `timeoutIntervalForResource`: a slow-but-progressing download must
    /// not be cut off, only a host that sends nothing at all.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }

    /// What one attempt produced: an image, or the reason there is not one.
    enum Outcome: Sendable {
        case image(UIImage)
        case failed(AvatarFailureCache.Reason)

        /// The image, if there is one. Failures are filed by whichever caller started the
        /// attempt, so a caller that merely joined one in flight needs only this.
        var succeeded: UIImage? {
            switch self {
            case let .image(image): image
            case .failed: nil
            }
        }
    }

    /// The already-decoded avatar for `url` at `pixelSize`, without suspending.
    ///
    /// `nonisolated` and synchronous on purpose: a view's `body` can consult it while
    /// laying out, so an avatar that is already in memory is drawn in the same frame the
    /// row appears in rather than one frame later.
    nonisolated func cachedImage(for url: URL, pixelSize: CGFloat) -> UIImage? {
        cache.image(forKey: Self.cacheKey(url: url, pixelSize: pixelSize))
    }

    /// The downsampled avatar for `url` at `pixelSize`: from cache when present, otherwise
    /// fetched and decoded once even under concurrent callers, and `nil` when there is no
    /// image to be had.
    func image(for url: URL, pixelSize: CGFloat) async -> UIImage? {
        let identity = Self.identity(of: url)
        let key = Self.cacheKey(identity: identity, pixelSize: pixelSize)
        if let cached = cache.image(forKey: key) { return cached }
        // A source that just failed is not asked for again until its entry ages out, so a
        // row scrolling in and out of a list cannot turn one 404 into a request per pass.
        if failures.isSuppressed(identity) { return nil }

        // `data:` URIs carry their own bytes: no session, and no in-flight entry either,
        // since the decode does not suspend and this actor already serialises, so a second
        // caller cannot arrive mid-decode — it arrives to a populated cache.
        if let dataURI = DataURI(url: url) {
            return apply(Self.decode(dataURI, pixelSize: pixelSize), identity: identity, key: key)
        }

        if let existing = inFlight[key] { return await existing.value.succeeded }

        let session = session
        let thumbnail = RelayMediaURL.thumbnail(for: url, pixelSize: pixelSize)
        let task = Task<Outcome, Never> {
            await Self.fetch(url, thumbnail: thumbnail, pixelSize: pixelSize, session: session)
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return apply(outcome, identity: identity, key: key)
    }

    /// Forgets every remembered failure, so suppressed sources are retried on their next
    /// request. The hook a manual "retry" or a reachability change would pull.
    func retryFailures() {
        failures.removeAll()
    }

    /// Files an outcome: cache the image, or remember the failure.
    private func apply(_ outcome: Outcome, identity: String, key: String) -> UIImage? {
        switch outcome {
        case let .image(image):
            cache.insert(image, forKey: key)
            return image
        case let .failed(reason):
            failures.record(identity, reason: reason)
            return nil
        }
    }
}

// MARK: - Keys

extension AvatarLoader {
    /// A short, stable identity for an avatar source.
    ///
    /// `absoluteString` is the obvious answer, and is exactly what an `https://` URL uses.
    /// A `data:` URI, though, *is* its own payload and may run to megabytes, so using it
    /// verbatim would park a copy of every inline avatar's bytes in the key tables of both
    /// caches. Data URIs are therefore identified by a digest of the URI: short,
    /// collision-free in practice, and stable across launches.
    nonisolated static func identity(of url: URL) -> String {
        guard url.scheme?.lowercased() == "data" else { return url.absoluteString }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return "data:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The cache key for one source at one target size, so the same artwork at 34 pt and
    /// at 96 pt caches as two entries rather than colliding into one.
    nonisolated static func cacheKey(url: URL, pixelSize: CGFloat) -> String {
        cacheKey(identity: identity(of: url), pixelSize: pixelSize)
    }

    nonisolated static func cacheKey(identity: String, pixelSize: CGFloat) -> String {
        "\(identity)|\(Int(pixelSize.rounded()))"
    }
}

// MARK: - Fetching

extension AvatarLoader {
    /// Fetches and decodes, preferring the relay's thumbnail and falling back to the
    /// original exactly once.
    ///
    /// `nonisolated` so this runs on the concurrent executor rather than on the loader.
    nonisolated static func fetch(
        _ url: URL,
        thumbnail: URL?,
        pixelSize: CGFloat,
        session: URLSession
    ) async -> Outcome {
        if let thumbnail {
            let outcome = await load(thumbnail, pixelSize: pixelSize, session: session)
            switch outcome {
            // Blobs uploaded before the relay generated thumbnails have none, so a missing
            // thumbnail falls through to the original. Only this case does, and only here:
            // the original is fetched directly, never re-derived, so there is no loop.
            case .failed(.notFound): break
            case .image, .failed: return outcome
            }
        }
        return await load(url, pixelSize: pixelSize, session: session)
    }

    private nonisolated static func load(
        _ url: URL,
        pixelSize: CGFloat,
        session: URLSession
    ) async -> Outcome {
        guard let (data, response) = try? await session.data(from: url) else {
            return .failed(.transport)
        }
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            // Only "gone" is treated as settled. A 5xx or a 403 gets the short transport
            // lifetime, because both plausibly change without the blob changing.
            let isGone = http.statusCode == 404 || http.statusCode == 410
            return .failed(isGone ? .notFound : .transport)
        }
        guard let image = downsample(data, maxPixelSize: pixelSize) else {
            return .failed(.undecodable)
        }
        return .image(image)
    }
}

// MARK: - Decoding

extension AvatarLoader {
    /// The image a `data:` payload decodes to.
    ///
    /// ImageIO for raster mediatypes, and the bounded SVG tile renderer for
    /// `image/svg+xml` — which ImageIO cannot read at all, since it ships no SVG decoder.
    /// A raster mediatype whose bytes turn out to be XML is retried as SVG, because a
    /// mislabelled payload is likelier than a raster ImageIO genuinely cannot open.
    nonisolated static func decode(_ dataURI: DataURI, pixelSize: CGFloat) -> Outcome {
        let decoded: UIImage? = if dataURI.isSVG {
            SVGAvatarRenderer.image(svg: dataURI.data, pixelSize: pixelSize)
        } else {
            downsample(dataURI.data, maxPixelSize: pixelSize)
                ?? mislabelledSVG(dataURI.data, pixelSize: pixelSize)
        }
        guard let decoded else { return .failed(.undecodable) }
        return .image(decoded)
    }

    /// The last resort for a payload whose mediatype claims a raster ImageIO could not
    /// open: if the bytes open like XML, try them as SVG.
    private nonisolated static func mislabelledSVG(_ data: Data, pixelSize: CGFloat) -> UIImage? {
        guard looksLikeXML(data) else { return nil }
        return SVGAvatarRenderer.image(svg: data, pixelSize: pixelSize)
    }

    /// Whether a payload opens like an XML or SVG document, ignoring leading whitespace.
    static func looksLikeXML(_ data: Data) -> Bool {
        let head = data.prefix(64).drop { $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }
        return head.starts(with: Data("<?xml".utf8)) || head.starts(with: Data("<svg".utf8))
    }

    /// Decodes `data` straight to a thumbnail no larger than `maxPixelSize` on its longest
    /// edge, so a large source never becomes a large in-memory bitmap. `nil` for data
    /// ImageIO cannot read — which includes every SVG, hence ``decode(_:pixelSize:)``.
    nonisolated static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }
        return UIImage(cgImage: thumbnail)
    }
}

/// A thread-safe, cost-bounded store of decoded avatars.
///
/// `NSCache` is documented as safe to add to, remove from, and query from several threads
/// without taking a lock, and it evicts under memory pressure on its own. It is not marked
/// `Sendable`, so the `@unchecked` conformance here asserts exactly that documented
/// guarantee and nothing more — which is what lets ``AvatarLoader`` hold this
/// `nonisolated` and answer cache hits without a hop.
final class AvatarImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    /// - Parameters:
    ///   - countLimit: A few screens of rows.
    ///   - totalCostLimit: A ceiling in bytes of bitmap. The count limit alone is not a
    ///     bound worth having: 256 entries is ~12 MB of 36-pt tiles but ~85 MB of 96-pt
    ///     ones, so the cost limit is what actually keeps the footprint flat.
    init(countLimit: Int = 256, totalCostLimit: Int = 16 * 1024 * 1024) {
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, forKey key: String) {
        cache.setObject(image, forKey: key as NSString, cost: Self.cost(of: image))
    }

    func removeAll() {
        cache.removeAllObjects()
    }

    /// The bitmap's footprint in bytes, which is what the cost limit is denominated in.
    private static func cost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }
}
