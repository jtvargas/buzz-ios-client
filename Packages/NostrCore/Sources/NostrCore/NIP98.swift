import CryptoKit
import Foundation

/// NIP-98 HTTP authentication.
///
/// Buzz's HTTP surface — the NIP-CW `/query` bridge in Phase 1, media upload
/// later — authenticates each request with a short-lived signed event carried in
/// an `Authorization` header rather than through the relay's WebSocket NIP-42
/// flow. The event is kind 27235 with empty content and four tags: `u` (the exact
/// request URL), `method` (the HTTP verb, upper-cased), `payload` (the SHA-256 of
/// the request body), and `nonce` (a fresh UUID). The header value is the scheme
/// word `Nostr` followed by the base64 of the event's compact JSON.
///
/// The tag set and header encoding mirror the Buzz HTTP client exactly, so a
/// header this type produces validates against the same relays that client talks
/// to. The `payload` tag is always present, including for a bodyless request,
/// where it is the SHA-256 of zero bytes — the server hashes the body it received
/// and compares, so a missing tag on an empty body would fail that check.
public enum NIP98 {
    /// The `Authorization` scheme word, with its trailing space.
    static let scheme = "Nostr "

    // MARK: - Building

    /// The signed kind 27235 event that authorises one HTTP request.
    ///
    /// Exposed apart from ``authorizationHeader(url:method:body:signer:)`` so a
    /// caller — or a test — can inspect the individual tags without first
    /// decoding the base64 the header wraps them in.
    ///
    /// - Parameters:
    ///   - url: The request URL; its absolute string becomes the `u` tag verbatim.
    ///   - method: The HTTP method; stored upper-cased in the `method` tag.
    ///   - body: The request body, hashed into the `payload` tag. Defaults to the
    ///     empty body, whose hash is the SHA-256 of zero bytes.
    ///   - signer: The identity the authorisation is attributed to.
    public static func authorizationEvent(
        url: URL,
        method: String,
        body: Data = Data(),
        signer: some EventSigner
    ) async throws -> NostrEvent {
        try await authorizationEvent(
            url: url,
            method: method,
            body: body,
            generated: GeneratedInputs(nonce: UUID().uuidString, createdAt: Date()),
            signer: signer
        )
    }

    /// The `Authorization` header value for one HTTP request.
    ///
    /// Format: `Nostr <base64(event JSON)>`, where the JSON is the compact,
    /// single-line encoding of the signed authorisation event.
    public static func authorizationHeader(
        url: URL,
        method: String,
        body: Data = Data(),
        signer: some EventSigner
    ) async throws -> String {
        let event = try await authorizationEvent(url: url, method: method, body: body, signer: signer)
        return try encodeHeader(for: event)
    }

    // MARK: - Validation

    /// Whether a received authorisation event authorises the described request.
    ///
    /// Checks, in order: the event is kind 27235; its `u`, `method`, and
    /// `payload` tags match the request being made; its `created_at` sits within
    /// `tolerance` of `now`; and its id hashes its own fields with a signature
    /// that verifies. A server pairs this with its own authorisation of the
    /// event's `pubkey`, which is outside this protocol-level check.
    ///
    /// - Parameters:
    ///   - now: The instant to judge freshness against; defaults to the present.
    ///   - tolerance: The half-width of the acceptance window in seconds. The
    ///     NIP-98-recommended 60 seconds is the default; the event's timestamp
    ///     may sit up to this far either side of `now`.
    public static func validate(
        event: NostrEvent,
        url: URL,
        method: String,
        body: Data = Data(),
        now: Date = Date(),
        tolerance: TimeInterval = 60
    ) -> Bool {
        guard event.kind == .httpAuthentication else { return false }
        guard event.firstValue(forTag: "u") == url.absoluteString,
              event.firstValue(forTag: "method")?.uppercased() == method.uppercased(),
              event.firstValue(forTag: "payload") == payloadHash(for: body)
        else { return false }
        guard abs(event.date.timeIntervalSince(now)) <= tolerance else { return false }
        return event.isValid
    }

    /// Whether an `Authorization` header value authorises the described request.
    ///
    /// A convenience over ``validate(event:url:method:body:now:tolerance:)`` that
    /// first parses the header: it must carry the `Nostr` scheme and a base64
    /// payload that decodes to a kind 27235 event. Any parse failure is a
    /// rejection, not an error.
    public static func validate(
        header: String,
        url: URL,
        method: String,
        body: Data = Data(),
        now: Date = Date(),
        tolerance: TimeInterval = 60
    ) -> Bool {
        guard let event = decodeEvent(from: header) else { return false }
        return validate(event: event, url: url, method: method, body: body, now: now, tolerance: tolerance)
    }

    // MARK: - Deterministic building (internal)

    /// The values the public building path generates on its own: a fresh nonce
    /// and the current instant.
    ///
    /// The public entry points draw these implicitly, which is what every request
    /// wants but leaves the resulting event impossible to assert byte-for-byte.
    /// Surfacing them together lets tests inject fixed values and pin the exact
    /// wire format.
    struct GeneratedInputs {
        let nonce: String
        let createdAt: Date
    }

    /// The building path with the nonce and timestamp injected.
    static func authorizationEvent(
        url: URL,
        method: String,
        body: Data,
        generated: GeneratedInputs,
        signer: some EventSigner
    ) async throws -> NostrEvent {
        try await signer.sign(
            kind: .httpAuthentication,
            content: "",
            tags: [
                ["u", url.absoluteString],
                ["method", method.uppercased()],
                ["payload", payloadHash(for: body)],
                // A fresh nonce per request keeps two otherwise-identical requests
                // from producing the same event id, so a captured header cannot be
                // replayed as if it were the original.
                ["nonce", generated.nonce],
            ],
            createdAt: generated.createdAt
        )
    }

    /// The header path with the nonce and timestamp injected, for pinning tests.
    static func authorizationHeader(
        url: URL,
        method: String,
        body: Data,
        generated: GeneratedInputs,
        signer: some EventSigner
    ) async throws -> String {
        let event = try await authorizationEvent(
            url: url,
            method: method,
            body: body,
            generated: generated,
            signer: signer
        )
        return try encodeHeader(for: event)
    }

    // MARK: - Encoding helpers

    /// The lowercase-hex SHA-256 of a request body, as carried in the `payload`
    /// tag. Present for every request; an empty body hashes to the digest of zero
    /// bytes rather than being omitted.
    static func payloadHash(for body: Data) -> String {
        Data(SHA256.hash(data: body)).hexString
    }

    /// Wraps a signed event into a header value: `Nostr <base64(event JSON)>`.
    ///
    /// Keys are sorted and slashes left unescaped so the encoding is a stable,
    /// readable single line — the URL in the `u` tag reads as itself. The relay
    /// re-parses the JSON and recomputes the id, so this key order is a local
    /// determinism choice, not something the wire depends on.
    static func encodeHeader(for event: NostrEvent) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let json = try encoder.encode(event)
        return scheme + json.base64EncodedString()
    }

    /// Parses the event out of a header value, returning `nil` for anything that
    /// is not the `Nostr` scheme wrapping base64 of a decodable event.
    static func decodeEvent(from header: String) -> NostrEvent? {
        guard header.hasPrefix(scheme) else { return nil }
        let encoded = String(header.dropFirst(scheme.count))
        guard let json = Data(base64Encoded: encoded) else { return nil }
        return try? JSONDecoder().decode(NostrEvent.self, from: json)
    }
}
