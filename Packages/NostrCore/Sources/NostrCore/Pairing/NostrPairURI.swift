import Foundation

/// A parsed, validated `nostrpair://` QR payload (NIP-AB device pairing).
///
/// The QR the _source_ (desktop) displays is the authoritative bootstrap for a
/// pairing session: it carries the source's throwaway ephemeral public key, a
/// 32-byte session secret, and the relay(s) to meet on. It never carries any real
/// identity key — an intercepted QR yields only material useless without also
/// completing the SAS-verified handshake within the session window.
///
/// Parsing is deliberately strict (NIP-AB §QR Code Format): a lax parser here is a
/// security boundary, so every field is validated to the exact shape the spec
/// mandates and anything off-spec is rejected rather than coerced.
public struct NostrPairURI: Sendable, Equatable {
    /// The source's ephemeral x-only public key (BIP-340), learned from the QR.
    public let sourcePublicKey: PublicKey
    /// The 32-byte session secret, shared out-of-band via the QR. Salts the SAS and
    /// transcript derivations and authenticates the offer.
    public let sessionSecret: Data
    /// One or more relays to route pairing events through, in QR order. At least
    /// one is guaranteed; a multi-relay QR lists fallbacks.
    public let relays: [URL]
    /// The protocol version. Only `1` is understood; the parser rejects anything
    /// else so an old client surfaces "needs an update" rather than misbehaving.
    public let version: Int

    /// The scheme every pairing QR uses.
    public static let scheme = "nostrpair"
    /// The only protocol version this build implements (NIP-AB v1).
    public static let supportedVersion = 1
    /// The URI-length ceiling (NIP-AB `MAX_URI_LEN`), a DoS guard on QR scanning.
    public static let maxURILength = 2048

    public init(sourcePublicKey: PublicKey, sessionSecret: Data, relays: [URL], version: Int = 1) {
        self.sourcePublicKey = sourcePublicKey
        self.sessionSecret = sessionSecret
        self.relays = relays
        self.version = version
    }
}

// MARK: - Parsing

public extension NostrPairURI {
    /// Parses and strictly validates a `nostrpair://` URI.
    ///
    /// - Throws: ``NostrPairError`` for any deviation from NIP-AB §QR Code Format —
    ///   an over-long URI, a wrong scheme, a pubkey/secret that is not exactly 64
    ///   lowercase hex characters, an all-zero secret, a missing or non-WebSocket
    ///   relay, or an unrecognised version.
    init(parsing raw: String) throws {
        guard raw.count <= Self.maxURILength else { throw NostrPairError.uriTooLong(raw.count) }

        guard let separatorRange = raw.range(of: "://") else {
            throw NostrPairError.malformedURI
        }
        let scheme = raw[raw.startIndex ..< separatorRange.lowerBound]
        guard scheme.lowercased() == Self.scheme else {
            throw NostrPairError.unexpectedScheme(String(scheme))
        }

        let body = raw[separatorRange.upperBound...]
        let authority: Substring
        let query: Substring
        if let questionMark = body.firstIndex(of: "?") {
            authority = body[body.startIndex ..< questionMark]
            query = body[body.index(after: questionMark)...]
        } else {
            authority = body
            query = ""
        }

        guard Self.isLowercaseHex(authority, length: 64),
              let pubkeyBytes = Data(hexString: String(authority)),
              let sourceKey = PublicKey(rawRepresentation: pubkeyBytes)
        else { throw NostrPairError.invalidSourcePublicKey }

        let parameters = QueryParameters(query)

        guard let secretHex = parameters.secret else { throw NostrPairError.missingSessionSecret }
        guard Self.isLowercaseHex(secretHex, length: 64),
              let secret = Data(hexString: secretHex), secret.count == 32
        else { throw NostrPairError.invalidSessionSecret }
        guard secret.contains(where: { $0 != 0 }) else { throw NostrPairError.zeroSessionSecret }

        let relays = parameters.relays.compactMap(Self.websocketURL)
        guard !relays.isEmpty else { throw NostrPairError.missingRelay }

        let version = try Self.resolveVersion(parameters.version)

        self.init(sourcePublicKey: sourceKey, sessionSecret: secret, relays: relays, version: version)
    }

    // MARK: - Field helpers

    /// Whether `value` is exactly `length` lowercase-hex characters (`0-9a-f`). The
    /// case check is deliberate: NIP-AB mandates lowercase, and `Data(hexString:)`
    /// alone would silently accept uppercase.
    private static func isLowercaseHex(_ value: some StringProtocol, length: Int) -> Bool {
        guard value.count == length else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x61 && byte <= 0x66)
        }
    }

    /// Validates and normalises a relay URL: a `ws`/`wss` URL with a non-empty host.
    private static func websocketURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Maps an absent version to the default `1`, accepts an explicit `1`, and
    /// rejects anything else — including a non-integer — as unsupported so the UI
    /// can tell the user to update rather than failing opaquely.
    private static func resolveVersion(_ raw: String?) throws -> Int {
        guard let raw else { return supportedVersion }
        guard let value = Int(raw) else { throw NostrPairError.unsupportedVersion(raw) }
        guard value == supportedVersion else { throw NostrPairError.unsupportedVersion(raw) }
        return value
    }

    /// The query fields NIP-AB defines, extracted from the raw query string.
    ///
    /// Values are percent-decoded; unknown parameters are ignored (NIP-AB forward
    /// compatibility). `secret` and `v` take the first occurrence; `relay` collects
    /// every occurrence in order for the multi-relay case.
    private struct QueryParameters {
        var secret: String?
        var relays: [String] = []
        var version: String?

        init(_ query: Substring) {
            for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
                let key: Substring
                let value: Substring
                if let equals = pair.firstIndex(of: "=") {
                    key = pair[pair.startIndex ..< equals]
                    value = pair[pair.index(after: equals)...]
                } else {
                    key = pair
                    value = ""
                }
                let decoded = String(value).removingPercentEncoding ?? String(value)
                switch key {
                case "secret": if secret == nil { secret = decoded }
                case "relay": relays.append(decoded)
                case "v": if version == nil { version = decoded }
                default: continue
                }
            }
        }
    }
}
