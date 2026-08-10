import BuzzKit
import CryptoKit
import ImageIO
import UIKit

/// Loads, downsamples, caches, and de-duplicates remote image requests.
///
/// An actor so the caches and the in-flight table are mutated without a lock, and so a
/// burst of rows asking for the same artwork while scrolling shares one fetch and one
/// decode rather than starting a request each.
///
/// The actor is only a *coordinator*. Every expensive step happens off it:
///
/// - Fetching, parsing a `data:` URI, and decoding all run inside
///   ``resolve(_:thumbnail:pixelSize:session:)``, a `nonisolated` `async` function, so
///   Swift hops it to the concurrent executor (SE-0338) instead of holding this actor for
///   the length of a network round trip, a percent-decode of the whole payload, and an
///   ImageIO or Core Graphics raster.
/// - Cache *hits* never reach the actor at all — see ``cachedImage(for:pixelSize:)``.
///
/// # Why there is more than one of these
///
/// The pipeline is shared; the *budget* is not. An avatar decodes to a 34-pt tile —
/// ~13 KB of bitmap — and a screen holds a dozen of them. A message picture decodes to
/// the 320×240-pt box ``MessageMediaLayout`` reserves, which on a 3× screen is ~2.7 MB,
/// two hundred times as much. Sharing one cost-bounded cache between them means one
/// scroll through a picture-heavy channel evicts every face in the conversation, and the
/// avatars then re-decode on the way back. So each caller owns an instance with a cache
/// sized for what it stores — ``shared`` for avatars, ``messageMedia`` for attachments —
/// and they share every line of the fetch, downsample, de-duplication and negative-cache
/// logic below.
actor RemoteImageLoader {
    /// The loader avatars are drawn through: many small tiles, a small budget.
    static let shared = RemoteImageLoader()

    /// Decoded images, keyed by source identity and target pixel size.
    ///
    /// A `nonisolated let` over a thread-safe cache rather than actor state, so the main
    /// actor can peek synchronously while rendering. That peek is the difference between a
    /// row scrolling back in showing its picture immediately and showing one frame of
    /// monogram first, because `.task` runs *after* the frame it was attached to.
    private nonisolated let cache: RemoteImageCache
    private var inFlight: [String: Task<Outcome, Never>] = [:]
    private var failures = RemoteImageFailureCache()
    private let session: URLSession
    /// The signed grant relay media is fetched with, once there is an identity to sign
    /// one. `nil` until a session mounts, and again after it ends.
    private var authorization: (any MediaReadAuthorizing)?
    /// The active community's exact staged bytes, keyed by the predicted URL's filename.
    private var stagingDirectory: URL?

    init(session: URLSession = RemoteImageLoader.makeSession(), cache: RemoteImageCache = RemoteImageCache()) {
        self.session = session
        self.cache = cache
    }

    /// Points the loader at the session's grant, or removes it when the session ends.
    ///
    /// Forgetting the remembered failures is part of the same act rather than a courtesy:
    /// against a relay that requires the grant, every fetch before it arrived came back
    /// `401` and is now suppressed for the negative cache's lifetime. Those entries
    /// describe a question that was asked without credentials, so they say nothing about
    /// the request the loader would make now — and leaving them would hold a conversation
    /// blank for minutes after the thing that fixes it landed.
    func setAuthorization(_ provider: (any MediaReadAuthorizing)?) {
        authorization = provider
        failures.removeAll()
    }

    func setStagingDirectory(_ directory: URL?) {
        stagingDirectory = directory
        failures.removeAll()
    }

    /// The session images are fetched on.
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
        /// No image, and the URL that actually produced that answer — which for relay
        /// media is the *thumbnail* whenever one was tried. Carried so the failure is
        /// remembered against the thing that failed rather than against the original it
        /// was derived from, which is fetched at other sizes and may be perfectly good.
        case failed(RemoteImageFailureCache.Reason, url: URL)

        /// The image, if there is one. Failures are filed by whichever caller started the
        /// attempt, so a caller that merely joined one in flight needs only this.
        var succeeded: UIImage? {
            switch self {
            case let .image(image): image
            case .failed: nil
            }
        }
    }

    /// The already-decoded image for `url` at `pixelSize`, without suspending.
    ///
    /// `nonisolated` and synchronous on purpose: a view's `body` can consult it while
    /// laying out, so artwork that is already in memory is drawn in the same frame the
    /// row appears in rather than one frame later.
    nonisolated func cachedImage(for url: URL, pixelSize: CGFloat) -> UIImage? {
        cache.image(forKey: Self.cacheKey(url: url, pixelSize: pixelSize))
    }

    /// Hands back every decoded bitmap this loader is holding.
    ///
    /// `nonisolated` for the same reason the peek above is: the callers are
    /// ``AppCaches``, on the main actor, at moments — backgrounding, a session ending —
    /// where suspending on this actor would mean queueing behind an in-flight fetch.
    ///
    /// The remembered failures are deliberately left alone, unlike ``setAuthorization(_:)``:
    /// nothing about the *credentials* changed, so a source that 404ed a moment ago would
    /// 404 again, and forgetting that would turn one dropped cache into a fresh round of
    /// doomed requests on the way back.
    nonisolated func removeAll() {
        cache.removeAll()
    }

    /// The downsampled image for `url` at `pixelSize`: from cache when present, otherwise
    /// fetched and decoded once even under concurrent callers, and `nil` when there is no
    /// image to be had.
    func image(for url: URL, pixelSize: CGFloat) async -> UIImage? {
        // Resolved once and threaded through: for a `data:` URI this digests the payload,
        // and the two questions below and the cache key all want the same answer.
        let identity = Self.identity(of: url)
        let key = Self.cacheKey(identity: identity, pixelSize: pixelSize)
        if let cached = cache.image(forKey: key) { return cached }

        // Derived here rather than inside the attempt because the negative cache is keyed
        // by attempted URL, so knowing which URLs this request would try is what makes the
        // suppression question answerable.
        let thumbnail = RelayMediaURL.thumbnail(for: url, pixelSize: pixelSize)
        // A source that just failed is not asked for again until its entry ages out, so a
        // row scrolling in and out of a list cannot turn one 404 into a request per pass.
        if isSuppressed(identity, thumbnail: thumbnail) { return nil }

        // One entry per (source, size), which a `data:` URI needs as much as a fetch does:
        // its parse and raster now happen off this actor, so there is a suspension point
        // for a second caller to arrive in rather than a serialised decode they queue
        // behind.
        if let existing = inFlight[key] { return await existing.value.succeeded }

        // Both read off the actor here and passed down, rather than reached for inside the
        // attempt: the grant is minted on the concurrent executor with everything else, and
        // this actor keeps its one suspension point — the `await` on the task below — so a
        // second caller cannot slip past the in-flight table while a signature is in
        // progress and start a duplicate fetch.
        let session = session
        let authorization = authorization
        let stagingDirectory = stagingDirectory
        let task = Task<Outcome, Never> {
            await Self.resolve(
                url, thumbnail: thumbnail, pixelSize: pixelSize,
                session: session, authorization: authorization,
                stagingDirectory: stagingDirectory
            )
        }
        inFlight[key] = task
        let outcome = await task.value
        inFlight[key] = nil
        return apply(outcome, key: key)
    }

    /// Whether a request should be skipped because a URL it would attempt has just failed.
    ///
    /// Both candidates are consulted, because either can be the one that failed: a
    /// thumbnail that answered with a non-image body suppresses the sizes that would fetch
    /// *that thumbnail*, and leaves the original askable at a size where the thumbnail
    /// would never be derived at all.
    ///
    /// The original arrives already identified — see ``image(for:pixelSize:)`` — while a
    /// thumbnail is always relay `https://` media, whose identity is its own URL string.
    private func isSuppressed(_ identity: String, thumbnail: URL?) -> Bool {
        if let thumbnail, failures.isSuppressed(Self.identity(of: thumbnail)) { return true }
        return failures.isSuppressed(identity)
    }

    /// Forgets every remembered failure, so suppressed sources are retried on their next
    /// request. The hook a manual "retry" or a reachability change would pull.
    func retryFailures() {
        failures.removeAll()
    }

    /// Files an outcome: cache the image, or remember the failure against the URL that
    /// produced it.
    private func apply(_ outcome: Outcome, key: String) -> UIImage? {
        switch outcome {
        case let .image(image):
            cache.insert(image, forKey: key)
            return image
        case let .failed(reason, url):
            failures.record(Self.identity(of: url), reason: reason)
            return nil
        }
    }
}

// MARK: - Keys

extension RemoteImageLoader {
    /// A short, stable identity for an image source.
    ///
    /// `absoluteString` is the obvious answer, and is exactly what an `https://` URL uses.
    /// A `data:` URI, though, *is* its own payload and may run to megabytes, so using it
    /// verbatim would park a copy of every inline payload's bytes in the key tables of both
    /// caches. Data URIs are therefore identified by a digest of the URI: short,
    /// collision-free in practice, and stable across launches.
    nonisolated static func identity(of url: URL) -> String {
        guard url.scheme?.lowercased() == "data" else { return url.absoluteString }
        return "data:" + hexadecimal(SHA256.hash(data: Data(url.absoluteString.utf8)))
    }

    /// Lowercase hexadecimal for a digest, written out as one pass over its bytes.
    ///
    /// `map { String(format: "%02x", $0) }.joined()` is the idiomatic spelling and is
    /// measurably the expensive half of ``identity(of:)`` — thirty-two `String(format:)`
    /// calls, each parsing a format string and allocating, then an array and a join, for
    /// ~0.2 ms regardless of how large the payload being digested was. This runs on the
    /// main actor inside a view's `body` (``cachedImage(for:pixelSize:)``) on every pass
    /// for a `data:` source that is not in the cache, so it is worth not spending.
    private nonisolated static func hexadecimal(_ digest: SHA256.Digest) -> String {
        var text = ""
        text.reserveCapacity(SHA256.Digest.byteCount * 2)
        for byte in digest {
            text.append(Self.hexDigits[Int(byte >> 4)])
            text.append(Self.hexDigits[Int(byte & 0x0F)])
        }
        return text
    }

    private nonisolated static let hexDigits: [Character] = Array("0123456789abcdef")

    /// The cache key for one source at one target size, so the same artwork at 34 pt and
    /// at 96 pt caches as two entries rather than colliding into one.
    nonisolated static func cacheKey(url: URL, pixelSize: CGFloat) -> String {
        cacheKey(identity: identity(of: url), pixelSize: pixelSize)
    }

    nonisolated static func cacheKey(identity: String, pixelSize: CGFloat) -> String {
        "\(identity)|\(Int(pixelSize.rounded()))"
    }
}

// MARK: - Resolving

extension RemoteImageLoader {
    /// The image `url` resolves to: a `data:` URI's own payload, or a fetch of the relay's
    /// thumbnail falling back to the original.
    ///
    /// `nonisolated` *and* `async`, so a call from the actor hops to the concurrent
    /// executor (SE-0338) rather than running on the loader. That is what the `data:`
    /// branch needs as much as the network one: ``DataURI/init(url:)`` percent-decodes or
    /// base64-decodes every byte of a payload that may run to
    /// ``DataURI/maximumEncodedByteCount``, and the decode after it is an ImageIO or Core
    /// Graphics raster. Both are bounded, neither is cheap, and on the actor either one is
    /// a head-of-line block for every other avatar on screen.
    nonisolated static func resolve(
        _ url: URL,
        thumbnail: URL?,
        pixelSize: CGFloat,
        session: URLSession,
        authorization: (any MediaReadAuthorizing)? = nil,
        stagingDirectory: URL? = nil
    ) async -> Outcome {
        if let dataURI = DataURI(url: url) {
            guard let image = decode(dataURI, pixelSize: pixelSize) else {
                // The URI *is* the source, so it is also the URL the failure belongs to.
                return .failed(.undecodable, url: url)
            }
            return .image(image)
        }
        if let stagingDirectory,
           url.pathComponents.contains("media"),
           let data = try? Data(contentsOf: stagingDirectory.appendingPathComponent(url.lastPathComponent)),
           let image = downsample(data, maxPixelSize: pixelSize) {
            return .image(image)
        }
        return await fetch(
            url, thumbnail: thumbnail, pixelSize: pixelSize,
            session: session, authorization: authorization
        )
    }
}

// MARK: - Fetching

extension RemoteImageLoader {
    /// Fetches and decodes, preferring the relay's thumbnail and falling back to the
    /// original exactly once.
    ///
    /// `nonisolated` so this runs on the concurrent executor rather than on the loader.
    nonisolated static func fetch(
        _ url: URL,
        thumbnail: URL?,
        pixelSize: CGFloat,
        session: URLSession,
        authorization: (any MediaReadAuthorizing)? = nil
    ) async -> Outcome {
        if let thumbnail {
            let outcome = await load(
                thumbnail, pixelSize: pixelSize, session: session, authorization: authorization
            )
            switch outcome {
            // Blobs uploaded before the relay generated thumbnails have none, so a missing
            // thumbnail falls through to the original. Only this case does, and only here:
            // the original is fetched directly, never re-derived, so there is no loop.
            // Nothing is filed for it either — the outcome returned below is what gets
            // remembered, and a thumbnail 404 on the way to a good original is not a
            // failure of anything.
            case .failed(.notFound, _): break
            case .image, .failed: return outcome
            }
        }
        return await load(url, pixelSize: pixelSize, session: session, authorization: authorization)
    }

    private nonisolated static func load(
        _ url: URL,
        pixelSize: CGFloat,
        session: URLSession,
        authorization: (any MediaReadAuthorizing)?
    ) async -> Outcome {
        var request = URLRequest(url: url)
        // Sent whenever one can be minted, not only when the relay is known to insist:
        // whether a deployment requires it is its own configuration and nothing the client
        // is told, and a relay that does not care ignores the header. The authorizer
        // answers `nil` for anything that is not this relay's own media, so a picture
        // hosted elsewhere is still fetched as an anonymous request.
        if let header = await authorization?.authorization(for: url) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        guard let (data, response) = try? await session.data(for: request) else {
            return .failed(.transport, url: url)
        }
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            // Only "gone" is treated as settled. A 5xx or a 403 gets the short transport
            // lifetime, because both plausibly change without the blob changing.
            let isGone = http.statusCode == 404 || http.statusCode == 410
            return .failed(isGone ? .notFound : .transport, url: url)
        }
        guard let image = downsample(data, maxPixelSize: pixelSize) else {
            return .failed(.undecodable, url: url)
        }
        return .image(image)
    }
}

// MARK: - Decoding

extension RemoteImageLoader {
    /// The image a `data:` payload decodes to.
    ///
    /// ImageIO for raster mediatypes, and the bounded SVG tile renderer for
    /// `image/svg+xml` — which ImageIO cannot read at all, since it ships no SVG decoder.
    /// A raster mediatype whose bytes turn out to be XML is retried as SVG, because a
    /// mislabelled payload is likelier than a raster ImageIO genuinely cannot open.
    ///
    /// `nil` for a payload nothing here can read. Deliberately not an ``Outcome``: a
    /// decoder has no opinion about *which URL* failed, and that is the whole content of
    /// the failure case — ``resolve(_:thumbnail:pixelSize:session:)`` adds it.
    nonisolated static func decode(_ dataURI: DataURI, pixelSize: CGFloat) -> UIImage? {
        if dataURI.isSVG {
            return SVGAvatarRenderer.image(svg: dataURI.data, pixelSize: pixelSize)
        }
        return downsample(dataURI.data, maxPixelSize: pixelSize)
            ?? mislabelledSVG(dataURI.data, pixelSize: pixelSize)
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

/// A thread-safe, cost-bounded store of decoded images.
///
/// `NSCache` is documented as safe to add to, remove from, and query from several threads
/// without taking a lock, and it evicts under memory pressure on its own. It is not marked
/// `Sendable`, so the `@unchecked` conformance here asserts exactly that documented
/// guarantee and nothing more — which is what lets ``RemoteImageLoader`` hold this
/// `nonisolated` and answer cache hits without a hop.
final class RemoteImageCache: @unchecked Sendable {
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
