import CryptoKit
import Foundation
@testable import Hive
import Testing
import UIKit

/// The pure decisions the avatar pipeline makes around the pixels: what a `data:` URI
/// contains, whether the relay has a cheaper copy of a blob, whether a source is worth
/// asking for again, and which of the images in hand a view draws right now.
@Suite("Avatar sources")
struct AvatarSourceTests {
    /// The workspace owner's real avatar, copied verbatim from the relay. Percent-encoded
    /// rather than base64, and SVG rather than raster — the exact combination that made
    /// every profile picture in the app fall back to initials.
    static let ownerAvatar = """
    data:image/svg+xml,%3Csvg%20xmlns%3D%22http%3A%2F%2Fwww.w3.org%2F2000%2Fsvg%22%20\
    width%3D%22512%22%20height%3D%22512%22%20viewBox%3D%220%200%20512%20512%22%3E%3Crect%20\
    width%3D%22512%22%20height%3D%22512%22%20rx%3D%22256%22%20fill%3D%22%23FFF4CC%22%2F%3E%\
    3Ctext%20x%3D%2250%25%22%20y%3D%2256%25%22%20dominant-baseline%3D%22middle%22%20\
    text-anchor%3D%22middle%22%20font-size%3D%22258%22%3E%F0%9F%8E%A9%3C%2Ftext%3E%3C%2Fsvg%3E
    """

    /// What that URI decodes to, character for character.
    static let ownerAvatarSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="512" height="512" viewBox="0 0 512 512">\
    <rect width="512" height="512" rx="256" fill="#FFF4CC"/>\
    <text x="50%" y="56%" dominant-baseline="middle" text-anchor="middle" \
    font-size="258">\u{1F3A9}</text></svg>
    """

    /// A relay media URL in the shape the thumbnail rule matches.
    static let mediaURL = URL(
        string: "https://homelab.example.net/media/" +
            "d30e51a434671057056169000e6c181056fc4c63232056eeda5cc7094189828e.png"
    )!
}

// MARK: - Data URIs

extension AvatarSourceTests {
    @Test("the owner's percent-encoded SVG avatar decodes to its exact source text")
    func ownerAvatarDecodes() throws {
        let uri = try #require(DataURI(string: Self.ownerAvatar))

        #expect(uri.mediaType == "image/svg+xml")
        #expect(uri.isBase64 == false)
        #expect(uri.isSVG)
        #expect(String(data: uri.data, encoding: .utf8) == Self.ownerAvatarSVG)
    }

    @Test("a base64 payload decodes, with or without its padding")
    func base64Payloads() throws {
        let padded = try #require(DataURI(string: "data:image/png;base64,SGVsbG8h"))
        #expect(padded.mediaType == "image/png")
        #expect(padded.isBase64)
        #expect(String(data: padded.data, encoding: .utf8) == "Hello!")

        // "Hi" is `SGk=`; a producer that trimmed the padding still has to decode.
        let unpadded = try #require(DataURI(string: "data:application/octet-stream;base64,SGk"))
        #expect(String(data: unpadded.data, encoding: .utf8) == "Hi")

        // Some producers percent-escape the base64 alphabet, which the strict first pass
        // rejects outright: `%2B%2F8%3D` is `+/8=`, and only after unescaping does it
        // decode. Anything that skipped that step would drop the avatar entirely.
        let escaped = try #require(DataURI(string: "data:image/png;base64,%2B%2F8%3D"))
        #expect(Array(escaped.data) == [0xFB, 0xFF])
    }

    @Test("an omitted mediatype defaults to text/plain, with or without the base64 marker")
    func defaultMediaType() throws {
        let plain = try #require(DataURI(string: "data:,Hello%2C%20World%21"))
        #expect(plain.mediaType == DataURI.defaultMediaType)
        #expect(plain.isBase64 == false)
        #expect(String(data: plain.data, encoding: .utf8) == "Hello, World!")

        let encoded = try #require(DataURI(string: "data:;base64,SGVsbG8h"))
        #expect(encoded.mediaType == DataURI.defaultMediaType)
        #expect(encoded.isBase64)
        #expect(String(data: encoded.data, encoding: .utf8) == "Hello!")
    }

    @Test("mediatype parameters are stripped and the scheme is case-insensitive")
    func mediaTypeNormalization() throws {
        let uri = try #require(DataURI(string: "DATA:image/SVG+XML;charset=utf-8,%3Csvg%2F%3E"))
        #expect(uri.mediaType == "image/svg+xml")
        #expect(uri.isSVG)
        #expect(uri.isBase64 == false)
    }

    @Test("a `+` in a non-base64 payload stays a plus, because a data URI is not a form")
    func plusIsLiteral() throws {
        let uri = try #require(DataURI(string: "data:text/plain,a+b"))
        #expect(String(data: uri.data, encoding: .utf8) == "a+b")
    }

    @Test("malformed input decodes to nil rather than to plausible garbage")
    func malformedInput() {
        // Not a data URI at all.
        #expect(DataURI(string: "https://example.com/a.png") == nil)
        // No comma, so no payload boundary.
        #expect(DataURI(string: "data:image/png;base64") == nil)
        // Truncated and non-hex percent escapes.
        #expect(DataURI(string: "data:text/plain,abc%") == nil)
        #expect(DataURI(string: "data:text/plain,abc%F") == nil)
        #expect(DataURI(string: "data:text/plain,abc%ZZ") == nil)
        // Base64 that is not base64 — one character over a multiple of four can never be.
        #expect(DataURI(string: "data:image/png;base64,SGVsbG8hZ") == nil)
        #expect(DataURI(string: "data:image/png;base64,not base64 at all!") == nil)
        // Empty string, and the bare scheme.
        #expect(DataURI(string: "") == nil)
        #expect(DataURI(string: "data:") == nil)
    }

    @Test("a payload over the cap is refused before it is decoded")
    func payloadCap() {
        let oversized = "data:text/plain," + String(repeating: "a", count: 64)
        #expect(DataURI(string: oversized, maximumEncodedByteCount: 32) == nil)
        #expect(DataURI(string: oversized, maximumEncodedByteCount: 1024) != nil)
        // The real cap is well above the owner's 425-byte avatar.
        #expect(Self.ownerAvatar.utf8.count < DataURI.maximumEncodedByteCount)
    }

    @Test("the URL initialiser accepts only the data scheme, and round-trips the payload")
    func urlInitializer() throws {
        let url = try #require(URL(string: Self.ownerAvatar))
        let uri = try #require(DataURI(url: url))
        #expect(String(data: uri.data, encoding: .utf8) == Self.ownerAvatarSVG)

        #expect(DataURI(url: Self.mediaURL) == nil)
    }
}

// MARK: - Relay thumbnails

extension AvatarSourceTests {
    @Test("a relay media URL derives its thumbnail sibling")
    func derivesThumbnail() throws {
        let thumbnail = try #require(RelayMediaURL.thumbnail(for: Self.mediaURL))
        #expect(thumbnail.absoluteString == "https://homelab.example.net/media/" +
            "d30e51a434671057056169000e6c181056fc4c63232056eeda5cc7094189828e.thumb.jpg")
    }

    @Test("every avatar the app draws is inside the thumbnail's own resolution")
    func avatarSizesFitTheThumbnail() {
        // The rationale for preferring the thumbnail is that no avatar the app draws needs
        // more resolution than it has. That is an argument about two size constants, so it
        // is asserted against them rather than restated in a comment: raising either past
        // this bound inverts the rationale, and would do it silently.
        let largest = max(MessageRowMetrics.avatarSize, ProfileSheetView.avatarSize)
        #expect(largest == 96)
        #expect(largest * 3 <= RelayMediaURL.thumbnailMaximumPixelSize)
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: largest * 3) != nil)
    }

    @Test("the thumbnail is used up to its own resolution and no further")
    func thumbnailSizeThreshold() {
        // Every avatar the app draws today is inside the bound: the largest is the 96-pt
        // profile header, which is 288 px on a 3x screen.
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: 108) != nil)
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: 288) != nil)
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: 320) != nil)
        // Past 320 the thumbnail would have to be upscaled, so the original wins.
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: 321) == nil)
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: 1024) == nil)
        #expect(RelayMediaURL.thumbnail(for: Self.mediaURL, pixelSize: .infinity) == nil)
        #expect(RelayMediaURL.thumbnailMaximumPixelSize == 320)
    }

    @Test("query and fragment survive the rewrite")
    func preservesQuery() throws {
        let signed = try #require(URL(string: Self.mediaURL.absoluteString + "?sig=abc#frag"))
        let thumbnail = try #require(RelayMediaURL.thumbnail(for: signed))
        #expect(thumbnail.query == "sig=abc")
        #expect(thumbnail.fragment == "frag")
        #expect(thumbnail.path.hasSuffix(".thumb.jpg"))
    }

    @Test("anything that is not the relay's media shape is left alone")
    func rejectsOtherURLs() throws {
        let digest = String(repeating: "a", count: 64)
        let cases = [
            // Not under a `media` directory.
            "https://host.net/blobs/\(digest).png",
            // Digest too short, too long, and not hexadecimal.
            "https://host.net/media/\(String(repeating: "a", count: 63)).png",
            "https://host.net/media/\(String(repeating: "a", count: 65)).png",
            "https://host.net/media/\(String(repeating: "z", count: 64)).png",
            // No extension to replace.
            "https://host.net/media/\(digest)",
            // Already a thumbnail: the stem is `<hex>.thumb`, which is not 64 hex
            // characters, so there is no `.thumb.thumb.jpg` to derive.
            "https://host.net/media/\(digest).thumb.jpg",
            // Not an HTTP scheme.
            "file:///media/\(digest).png",
        ]
        for string in cases {
            let url = try #require(URL(string: string), "\(string) should parse")
            #expect(RelayMediaURL.thumbnail(for: url) == nil, "\(string) should not match")
        }

        // And a data URI, which has no path shape at all.
        let dataURL = try #require(URL(string: Self.ownerAvatar))
        #expect(RelayMediaURL.thumbnail(for: dataURL) == nil)
    }
}

// MARK: - Negative cache

extension AvatarSourceTests {
    @Test("a recorded failure suppresses requests until its own lifetime is up")
    func failureLifetimes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = AvatarFailureCache()
        cache.record("gone", reason: .notFound, now: start)
        cache.record("broken", reason: .undecodable, now: start)
        cache.record("offline", reason: .transport, now: start)

        #expect(cache.isSuppressed("gone", now: start))
        #expect(cache.isSuppressed("broken", now: start))
        #expect(cache.isSuppressed("offline", now: start))
        #expect(cache.isSuppressed("never recorded", now: start) == false)

        // Thirty seconds on: the transport failure is forgiven — this is what lets avatars
        // fill in when the device walks back onto the tailnet — while the two settled
        // answers are still remembered.
        let later = start.addingTimeInterval(31)
        #expect(cache.isSuppressed("offline", now: later) == false)
        #expect(cache.isSuppressed("gone", now: later))
        #expect(cache.isSuppressed("broken", now: later))

        // Ten minutes on, nothing is suppressed.
        let muchLater = start.addingTimeInterval(601)
        #expect(cache.isSuppressed("gone", now: muchLater) == false)
        #expect(cache.isSuppressed("broken", now: muchLater) == false)
    }

    @Test("re-recording a key refreshes its expiry without adding an entry")
    func reRecordRefreshes() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = AvatarFailureCache()
        cache.record("offline", reason: .transport, now: start)
        cache.record("offline", reason: .transport, now: start.addingTimeInterval(20))

        #expect(cache.count == 1)
        #expect(cache.isSuppressed("offline", now: start.addingTimeInterval(31)))
        #expect(cache.isSuppressed("offline", now: start.addingTimeInterval(51)) == false)
    }

    @Test("the cache holds its bound, evicting the oldest recorded first")
    func boundedCapacity() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = AvatarFailureCache()
        let overflow = AvatarFailureCache.capacity + 50
        for index in 0 ..< overflow {
            cache.record("key-\(index)", reason: .notFound, now: start)
        }

        #expect(cache.count == AvatarFailureCache.capacity)
        // The first 50 were pushed out; the last 50 are still held.
        #expect(cache.isSuppressed("key-0", now: start) == false)
        #expect(cache.isSuppressed("key-49", now: start) == false)
        #expect(cache.isSuppressed("key-50", now: start))
        #expect(cache.isSuppressed("key-\(overflow - 1)", now: start))
    }

    @Test("removeAll forgets everything, so a retry is a real retry")
    func removeAllClears() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var cache = AvatarFailureCache()
        cache.record("gone", reason: .notFound, now: start)
        cache.removeAll()

        #expect(cache.count == 0)
        #expect(cache.isSuppressed("gone", now: start) == false)
    }
}

// MARK: - Cache keys

extension AvatarSourceTests {
    @Test("two sizes of one avatar are two cache entries, and a data URI is not its own key")
    func cacheKeys() throws {
        let small = AvatarLoader.cacheKey(url: Self.mediaURL, pixelSize: 108)
        let large = AvatarLoader.cacheKey(url: Self.mediaURL, pixelSize: 288)
        #expect(small != large)
        #expect(small.hasPrefix(Self.mediaURL.absoluteString))

        // A data URI is identified by a digest, not by its own bytes: a megabyte of inline
        // avatar must not become a megabyte of dictionary key.
        let dataURL = try #require(URL(string: Self.ownerAvatar))
        let identity = AvatarLoader.identity(of: dataURL)
        #expect(identity.count == 69) // "data:" plus 64 hexadecimal characters
        #expect(identity.hasPrefix("data:"))
        #expect(identity != dataURL.absoluteString)
        // Stable, so the same avatar hits the same entry on every pass.
        #expect(AvatarLoader.identity(of: dataURL) == identity)

        // The digest is spelled out by hand — `String(format: "%02x")` thirty-two times was
        // the measured cost of this call, and it is paid on the main actor inside `body`.
        // The idiomatic spelling is the oracle for the hand-written one.
        let expected = SHA256.hash(data: Data(dataURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(identity == "data:" + expected)
    }
}

// MARK: - What is drawn

extension AvatarSourceTests {
    private static func request(_ url: String?, _ pixelSize: CGFloat) -> AvatarView.Request {
        AvatarView.Request(url: url.flatMap(URL.init(string:)), pixelSize: pixelSize)
    }

    private static func tile(_ color: UIColor) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    @Test("a text-size change keeps the picture on screen, but a new subject never does")
    func drawnKeepsTheSubjectAcrossAResize() {
        let subject = "https://host.net/media/\(String(repeating: "a", count: 64)).png"
        let other = "https://host.net/media/\(String(repeating: "b", count: 64)).png"
        let resolvedImage = Self.tile(.systemRed)
        let cachedImage = Self.tile(.systemBlue)
        let resolved = AvatarView.Resolved(request: Self.request(subject, 102), image: resolvedImage)

        // Computed outside the `#expect`s: a closure that counts its own calls is not
        // `Sendable`, and the macro's expansion sends what it is handed.
        var peeks = 0
        let peeking: (URL, CGFloat) -> UIImage? = { _, _ in
            peeks += 1
            return cachedImage
        }
        let empty: (URL, CGFloat) -> UIImage? = { _, _ in nil }

        // The exact request: resolved state answers, and the cache is not even consulted —
        // for a `data:` avatar that lookup digests the whole URI on the main actor.
        let exact = AvatarView.drawn(resolved: resolved, request: Self.request(subject, 102), cached: peeking)
        #expect(exact === resolvedImage)
        #expect(peeks == 0)

        // One Dynamic Type step changes the pixel size of every avatar on screen at once,
        // because it is derived from a `@ScaledMetric`. The cache answers for the new size
        // when it can…
        let resized = AvatarView.drawn(resolved: resolved, request: Self.request(subject, 153), cached: peeking)
        #expect(resized === cachedImage)
        #expect(peeks == 1)
        // …and when it cannot, the bitmap in hand is drawn while the new size decodes. The
        // frame is fixed and the content is `.scaledToFill()`, so redrawing it at another
        // resolution costs nothing — and refusing to was a whole list of monograms until a
        // full round of decodes came back.
        let resizedCold = AvatarView.drawn(resolved: resolved, request: Self.request(subject, 153), cached: empty)
        #expect(resizedCold === resolvedImage)

        // A different subject is the one thing the identity check must refuse: a row reused
        // for another author draws its monogram, never the previous author's face.
        let stale = AvatarView.drawn(resolved: resolved, request: Self.request(other, 102), cached: empty)
        #expect(stale == nil)
        // And no artwork at all is the monogram, whatever is still resolved.
        let artless = AvatarView.drawn(resolved: resolved, request: Self.request(nil, 102), cached: peeking)
        #expect(artless == nil)
    }
}
