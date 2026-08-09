import CryptoKit
import Foundation
import NostrCore
import os

/// What the relay says back when it has stored a blob.
///
/// The relay's answer remains authoritative, but an image descriptor is also
/// predictable from the exact scrubbed bytes: the client hashes and measures the
/// picture, derives its MIME type and thumbnail URL, and makes its own BlurHash.
/// The relay's BlurHash is deliberately different because it resamples with a
/// different image stack; every other field used by ``imetaTag()`` must agree.
///
/// `duration`, `image` and `filename` are carried but unused by the image path.
/// They are what a video or a file attachment will need, and dropping them here
/// would mean re-deriving them at the point the second kind of attachment
/// arrives.
public struct BlobDescriptor: Sendable, Equatable, Codable {
    public let url: String
    public let sha256: String
    public let size: Int
    public let type: String
    public let uploaded: Int
    public let dim: String?
    public let blurhash: String?
    public let thumb: String?
    public let duration: Double?
    public let image: String?
    public let filename: String?

    public init(
        url: String,
        sha256: String,
        size: Int,
        type: String,
        uploaded: Int,
        dim: String? = nil,
        blurhash: String? = nil,
        thumb: String? = nil,
        duration: Double? = nil,
        image: String? = nil,
        filename: String? = nil
    ) {
        self.url = url
        self.sha256 = sha256
        self.size = size
        self.type = type
        self.uploaded = uploaded
        self.dim = dim
        self.blurhash = blurhash
        self.thumb = thumb
        self.duration = duration
        self.image = image
        self.filename = filename
    }

    /// Whether this blob is a picture, by the type the relay assigned it.
    public var isImage: Bool { type.hasPrefix("image/") }

    /// The NIP-92 `imeta` tag describing this blob.
    ///
    /// Field order and spelling match the mobile client's `toImetaTag()` exactly
    /// (`buzz/mobile/lib/shared/relay/media_upload.dart`), because both clients'
    /// messages are read by each other and by the relay. The optional fields are
    /// omitted rather than sent empty — an `imeta` entry is a space-separated
    /// `key value` pair, and a valueless key is not one.
    public func imetaTag() -> [String] {
        var tag = [
            "imeta",
            "url \(url)",
            "m \(type)",
            "x \(sha256)",
            "size \(size)",
        ]
        if let dim { tag.append("dim \(dim)") }
        if let blurhash { tag.append("blurhash \(blurhash)") }
        if let thumb { tag.append("thumb \(thumb)") }
        if let duration { tag.append("duration \(duration)") }
        if let image { tag.append("image \(image)") }
        if let filename { tag.append("filename \(filename)") }
        return tag
    }

    /// How the blob appears in the message body.
    ///
    /// A picture and a video are markdown *images*; anything else is a link
    /// carrying its filename, with the characters that would break the link
    /// syntax escaped. Same rule as the mobile client, and the reason Hive can
    /// already render everything it sends: the inline renderer has understood
    /// markdown images since inline pictures shipped.
    public func markdownReference() -> String {
        if type.hasPrefix("video/") { return "![video](\(url))" }
        if isImage { return "![image](\(url))" }
        let label = (filename ?? "file")
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        return "[\(label)](\(url))"
    }

}

/// Putting staged bytes on the blob store.
///
/// A seam in front of ``MediaUploadClient`` for the same reason `MessageSending`
/// sits in front of the engine: a durable media pump must be testable without a
/// relay while it resumes, bounds, and retries uploads independently of a composer.
public protocol MediaUploading: Sendable {
    /// Uploads `data` and returns what the relay stored, throwing
    /// ``MediaUploadError`` when it will not.
    func upload(data: Data, mimeType: String, filename: String?) async throws -> BlobDescriptor
}

/// Uploading a blob is a `PUT`, which ``HTTPTransport`` does not do.
///
/// A separate, one-method seam rather than a fifth method on `HTTPTransport`:
/// that protocol has four conformers, three of them test doubles, and none of
/// them has any business growing a method for a verb only this client uses. The
/// production transport conforms to both.
public protocol MediaUploadTransport: Sendable {
    /// Performs a `PUT` of `body` to `url` under `headers`, returning the raw
    /// response body and status. A non-2xx status is returned, not thrown — the
    /// caller interprets it, exactly as ``HTTPTransport/post(body:to:headers:)``
    /// does.
    func put(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int)
}

/// What can go wrong between choosing a picture and holding a descriptor.
public enum MediaUploadError: Error, Equatable, Sendable {
    /// The relay refused this picture on policy grounds — 415 or 422 for a type
    /// it otherwise accepts. Separated from ``failed`` because it is the one
    /// failure a reader can do something about, and the one a client must not
    /// retry unchanged.
    case rejectedByPolicy
    /// The relay is already carrying as many uploads as it will take from this
    /// identity at once — a 429.
    ///
    /// Its own case because it is the one refusal that says *later*, not *no*:
    /// the bytes are fine and the relay is willing, so the only correct response
    /// is to wait and offer them again. Folding it into ``failed`` cost a picture
    /// out of every five-picture message, because the relay's ceiling is two per
    /// pubkey (`buzz-relay` `BUZZ_MEDIA_MAX_CONCURRENT_UPLOADS_PER_PUBKEY`) and
    /// nothing here backed off.
    case tooManyConcurrent
    /// The relay answered, and the answer was not success.
    case failed(status: Int, body: String)
    /// The relay answered with success and a body that is not a descriptor.
    case malformedResponse
    /// This file's type is not one the relay stores.
    case unsupportedType(String)
    /// The file is larger than the relay will take, refused before the bytes go.
    case tooLarge(bytes: Int, max: Int)
}

/// Puts bytes on the relay's blob store and hands back what it stored.
///
/// # The contract, and where it came from
///
/// Read out of the mobile client rather than invented, so both clients speak the
/// same thing to the same relay:
///
/// - `PUT {base}/upload`, falling back to `/media/upload` on 404 or 405. The
///   fallback is not defensive coding — it is a relay old enough to predate the
///   short path, and the mobile client carries the same two.
/// - `Authorization: Nostr <base64url(event)>`, the event being a **kind 24242**
///   Blossom BUD-01 authorisation tagged `t=upload`, `x=<sha256>`, an
///   `expiration`, and the `server` authority.
/// - `Content-Type` of the blob, and `X-SHA-256` repeating the hash.
///
/// # Two encodings that look alike and are not
///
/// The header is **base64url with its padding stripped**. NostrCore's
/// ``NIP98`` builds a superficially identical `Nostr <base64…>` header using
/// *standard* base64, for a different kind entirely (27235, with `u`/`method`/
/// `payload` tags). Reusing it here would produce a header the relay rejects for
/// two independent reasons. They are separate on purpose.
public struct MediaUploadClient: Sendable {
    /// The kind of a Blossom BUD-01 authorisation event.
    public static let authorizationKind = EventKind(rawValue: 24242)

    /// How long an upload authorisation stays valid. Matches the mobile client.
    static let authorizationLifetime: TimeInterval = 600

    #if DEBUG
    static let predictionLog = Logger(subsystem: "BuzzKit", category: "MediaUpload.prediction")
    #endif

    /// The types the relay stores as pictures.
    ///
    /// **HEIC is deliberately absent**: it is what an iPhone camera writes by default
    /// and the relay does not take it, so the picking side transcodes before it ever
    /// reaches here.
    public static let supportedImageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp",
    ]

    private let transport: any MediaUploadTransport
    private let baseURL: URL
    private let signer: any EventSigner
    private let now: @Sendable () -> Date

    public init(
        transport: any MediaUploadTransport,
        baseURL: URL,
        signer: some EventSigner,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.transport = transport
        self.baseURL = baseURL
        self.signer = signer
        self.now = now
    }

    /// Uploads `data` and returns what the relay stored.
    ///
    /// - Parameters:
    ///   - data: the bytes, already in a type the relay accepts.
    ///   - mimeType: the type those bytes are in.
    ///   - filename: carried onto the descriptor for a file attachment's label.
    ///     Pictures do not need it — they are rendered, not named.
    public func upload(
        data: Data,
        mimeType: String,
        filename: String? = nil
    ) async throws -> BlobDescriptor {
        if let failure = Self.policyFailure(mimeType: mimeType, byteCount: data.count) {
            throw failure
        }
        let digest = Self.sha256Hex(data)
        let headers = try await headers(sha256: digest, mimeType: mimeType)

        var (body, status) = try await transport.put(
            body: data,
            to: baseURL.appendingPathComponent("upload"),
            headers: headers
        )
        if status == 404 || status == 405 {
            (body, status) = try await transport.put(
                body: data,
                to: baseURL.appendingPathComponent("media").appendingPathComponent("upload"),
                headers: headers
            )
        }

        guard (200 ..< 300).contains(status) else {
            // 415 and 422 on a type we *do* support is the relay's own policy
            // speaking — the picture is intact and the wrong shape for it, which
            // is a different thing to tell a reader than "upload failed".
            if status == 415 || status == 422 { throw MediaUploadError.rejectedByPolicy }
            // 429 is the relay saying "not right now", not "not this picture" —
            // see ``MediaUploadError/tooManyConcurrent``. The caller waits and
            // offers the same bytes again rather than failing the message.
            if status == 429 { throw MediaUploadError.tooManyConcurrent }
            throw MediaUploadError.failed(
                status: status,
                body: String(data: body, encoding: .utf8) ?? ""
            )
        }
        guard var descriptor = try? JSONDecoder().decode(BlobDescriptor.self, from: body) else {
            throw MediaUploadError.malformedResponse
        }
        if let filename, descriptor.filename == nil {
            descriptor = descriptor.withFilename(filename)
        }
        #if DEBUG
        Self.assertPrediction(of: data, at: baseURL, filename: filename, matches: descriptor)
        #endif
        return descriptor
    }

    #if DEBUG
    /// The one-line P1 gate: the relay's answer still wins, while a mismatch is
    /// impossible to miss before a later phase signs the prediction into an event.
    static func assertPrediction(
        of data: Data,
        at baseURL: URL,
        filename: String?,
        matches actual: BlobDescriptor
    ) {
        // Unit seams may use arbitrary bytes, but every supported image that can
        // reach production must be predictable or this gate has found a defect.
        guard let format = ImageByteFormat.detect(data), format.isStoredByRelay else { return }
        guard let predicted = BlobDescriptor.predicted(
            data: data,
            baseURL: baseURL,
            filename: filename
        ) else {
            predictionLog.fault("Could not predict a supported image descriptor")
            assertionFailure("Media descriptor prediction could not be constructed")
            return
        }
        let matches = predicted.url == actual.url
            && predicted.sha256 == actual.sha256
            && predicted.size == actual.size
            && predicted.type == actual.type
            && predicted.thumb == actual.thumb
        guard !matches else { return }

        let expected = String(describing: predicted)
        let received = String(describing: actual)
        predictionLog.fault("Media descriptor prediction mismatch")
        predictionLog.fault("Predicted: \(expected, privacy: .public)")
        predictionLog.fault("Relay returned: \(received, privacy: .public)")
        assertionFailure("Media descriptor prediction did not match the relay")
    }
    #endif

    /// The three headers an upload carries.
    func headers(sha256: String, mimeType: String) async throws -> [String: String] {
        [
            "Authorization": try await authorizationHeader(sha256: sha256),
            "Content-Type": mimeType,
            "X-SHA-256": sha256,
        ]
    }

    /// `Nostr <base64url(event JSON), unpadded>`.
    func authorizationHeader(sha256: String) async throws -> String {
        var tags: [[String]] = [
            ["t", "upload"],
            ["x", sha256],
            ["expiration", String(Int(now().addingTimeInterval(Self.authorizationLifetime).timeIntervalSince1970))],
        ]
        if let authority = Self.serverAuthority(of: baseURL) {
            tags.append(["server", authority])
        }
        let event = try await signer.sign(
            kind: Self.authorizationKind,
            content: "Upload buzz-media",
            tags: tags,
            createdAt: now()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try "Nostr " + Self.base64URLUnpadded(encoder.encode(event))
    }

    /// The `server` tag's value: host, plus a port only when it is not the
    /// scheme's default. Lower-cased and stripped of a trailing dot, because the
    /// relay compares this string rather than parsing it.
    static func serverAuthority(of url: URL) -> String? {
        guard let host = url.host, !host.isEmpty else { return nil }
        let bracketed = host.contains(":") ? "[\(host)]" : host
        var authority = bracketed.lowercased()
        if authority.hasSuffix(".") { authority.removeLast() }
        if let port = url.port, !(port == 443 && url.scheme == "https"), !(port == 80 && url.scheme == "http") {
            authority += ":\(port)"
        }
        return authority
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Base64url, unpadded — RFC 4648 §5 with the `=` removed, which is what the
    /// relay's header parser expects.
    static func base64URLUnpadded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension BlobDescriptor {
    /// A copy naming the file. The relay does not always echo a filename back,
    /// and a file attachment has nothing else to be labelled with.
    func withFilename(_ value: String) -> BlobDescriptor {
        BlobDescriptor(
            url: url, sha256: sha256, size: size, type: type, uploaded: uploaded,
            dim: dim, blurhash: blurhash, thumb: thumb, duration: duration,
            image: image, filename: value
        )
    }
}

extension MediaUploadClient: MediaUploading {}

/// The production transport speaks both verbs; this is where the second one is
/// declared, because the seam it satisfies lives in this module.
extension URLSessionHTTPTransport: MediaUploadTransport {}
