import Foundation

/// A parsed `data:` URI (RFC 2397): the mediatype, whether the payload was base64, and
/// the decoded bytes.
///
/// Avatars arrive in-band in two forms, and both have to resolve without a network
/// round trip. Buzz's desktop client uploads *base64* raster data URIs to Blossom and
/// stores the resulting `https://` URL, but it deliberately passes *percent-encoded*
/// SVG emoji avatars through unchanged, so a `data:image/svg+xml,%3Csvg…` string is a
/// normal, long-lived value in the `profile` projection — the workspace owner's own
/// avatar is one of them.
///
/// `URLSession` will happily load a `data:` URL, so the naive path "works" right up to
/// the decode. It is still worth short-circuiting: the round trip through the loading
/// system is pure overhead for bytes we are already holding, and the mediatype is the
/// only thing that says whether ImageIO can read the payload at all.
struct DataURI: Equatable, Sendable {
    /// The lowercased `type/subtype` with parameters stripped, or ``defaultMediaType``
    /// when the URI omits one (RFC 2397 §2).
    let mediaType: String
    /// Whether the header carried the `;base64` marker.
    let isBase64: Bool
    /// The decoded payload.
    let data: Data
}

// MARK: - Parsing

extension DataURI {
    /// The mediatype a URI with no explicit one means, per RFC 2397 §2.
    static let defaultMediaType = "text/plain"

    /// The largest URI this will attempt, in UTF-8 bytes of the *encoded* string.
    ///
    /// Data URIs are attacker-supplied strings relayed from other people's profiles, so
    /// the cap is checked before anything is allocated. Checking the encoded length is
    /// enough to bound the decoded length too: percent-decoding only ever shrinks, and
    /// base64 decodes to three quarters. 4 MB is far above any real avatar (the owner's
    /// is 425 bytes) and far below a payload that could matter.
    static let maximumEncodedByteCount = 4 * 1024 * 1024

    /// Parses a `data:` URI string, or returns `nil` if it is not one, is over
    /// ``maximumEncodedByteCount``, or has a payload that does not decode.
    init?(string: String, maximumEncodedByteCount: Int = DataURI.maximumEncodedByteCount) {
        guard string.utf8.count <= maximumEncodedByteCount,
              string.prefix(5).lowercased() == "data:"
        else { return nil }

        let body = string.dropFirst(5)
        guard let comma = body.firstIndex(of: ",") else { return nil }
        let header = Self.header(body[body.startIndex ..< comma])
        let payload = body[body.index(after: comma)...]

        guard let data = header.isBase64
            ? Self.base64Decoding(payload)
            : Self.percentDecoding(payload)
        else { return nil }

        self.mediaType = header.mediaType
        self.isBase64 = header.isBase64
        self.data = data
    }

    /// Parses the URI a `URL` was built from, or returns `nil` for any other scheme.
    ///
    /// `URL(string:)` round-trips these exactly (verified against the owner's live
    /// avatar: 425 characters in, 425 out), so `absoluteString` is the original text and
    /// re-parsing it loses nothing.
    init?(url: URL, maximumEncodedByteCount: Int = DataURI.maximumEncodedByteCount) {
        guard url.scheme?.lowercased() == "data" else { return nil }
        self.init(string: url.absoluteString, maximumEncodedByteCount: maximumEncodedByteCount)
    }

    /// Whether the mediatype names SVG — the one image type ImageIO cannot decode.
    var isSVG: Bool { mediaType == "image/svg+xml" || mediaType == "image/svg" }

    /// Splits the part between `data:` and the comma into a mediatype and the base64
    /// flag.
    ///
    /// The first component is taken as the mediatype only when it looks like one (it
    /// contains a `/`), which keeps a malformed `data:base64,…` from being read as a
    /// mediatype called "base64"; parameters such as `;charset=utf-8` are dropped,
    /// since nothing here needs them.
    private static func header(_ text: Substring) -> (mediaType: String, isBase64: Bool) {
        var mediaType = defaultMediaType
        var isBase64 = false
        for (index, part) in text.split(separator: ";", omittingEmptySubsequences: false).enumerated() {
            let token = part.trimmingCharacters(in: .whitespaces).lowercased()
            if token == "base64" {
                isBase64 = true
            } else if index == 0, token.contains("/") {
                mediaType = token
            }
        }
        return (mediaType, isBase64)
    }
}

// MARK: - Payload decoding

extension DataURI {
    /// Percent-decodes a payload at the byte level.
    ///
    /// Deliberately *not* `String.removingPercentEncoding`: that decodes to a `String`,
    /// which forces the payload to be valid text, whereas a `data:` payload is bytes.
    /// Note too that `+` passes through as a literal plus — a data URI is not
    /// form-encoded, and both `image/svg+xml` payloads and the base64 alphabet rely on
    /// that. A `%` not followed by two hex digits is malformed and rejected outright
    /// rather than passed through, matching `decodeURIComponent`.
    static func percentDecoding<S: StringProtocol>(_ payload: S) -> Data? {
        var decoded = Data()
        decoded.reserveCapacity(payload.utf8.count)
        var bytes = payload.utf8.makeIterator()
        while let byte = bytes.next() {
            guard byte == UInt8(ascii: "%") else {
                decoded.append(byte)
                continue
            }
            guard let high = bytes.next().flatMap(hexNibble),
                  let low = bytes.next().flatMap(hexNibble)
            else { return nil }
            decoded.append(high << 4 | low)
        }
        return decoded
    }

    /// Base64-decodes a payload, tolerating the two deviations producers actually ship:
    /// missing `=` padding, and a percent-encoded alphabet (`%2B` for `+`).
    ///
    /// Strict decoding is attempted first so that genuinely malformed input still comes
    /// back as `nil` rather than as plausible-looking garbage — which is why
    /// `.ignoreUnknownCharacters` is not used anywhere here.
    static func base64Decoding<S: StringProtocol>(_ payload: S) -> Data? {
        let compact = String(payload.filter { !$0.isWhitespace })
        if let data = Data(base64Encoded: padded(compact)) { return data }
        guard let unescaped = percentDecoding(compact),
              let text = String(data: unescaped, encoding: .utf8)
        else { return nil }
        return Data(base64Encoded: padded(text))
    }

    /// Restores the `=` padding a producer may have trimmed. A length that is one more
    /// than a multiple of four cannot be base64 at all, and the three `=` this appends
    /// keep it failing rather than silently decoding.
    private static func padded(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0") ... UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a") ... UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A") ... UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}
