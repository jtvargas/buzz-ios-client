import Foundation
@testable import NostrCore
import Testing

/// The strict NIP-AB QR parse/validation matrix. A lax parser here is a security
/// boundary, so every off-spec input must be rejected rather than coerced.
@Suite struct NostrPairURITests {
    static let pubkey = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"
    static let secret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"

    private func uri(
        pubkey: String = pubkey,
        query: String = "secret=\(secret)&relay=wss%3A%2F%2Frelay.example.com&v=1"
    ) -> String {
        "nostrpair://\(pubkey)?\(query)"
    }

    // MARK: - Valid

    @Test func parsesAValidURI() throws {
        let parsed = try NostrPairURI(parsing: uri())
        #expect(parsed.sourcePublicKey.hex == Self.pubkey)
        #expect(parsed.sessionSecret.hexString == Self.secret)
        #expect(parsed.relays.map(\.absoluteString) == ["wss://relay.example.com"])
        #expect(parsed.version == 1)
    }

    @Test func defaultsVersionToOneWhenAbsent() throws {
        let parsed = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)&relay=wss%3A%2F%2Fr.example"))
        #expect(parsed.version == 1)
    }

    @Test func collectsMultipleRelaysInOrder() throws {
        let query = "secret=\(Self.secret)&relay=wss%3A%2F%2Fa.example&relay=ws%3A%2F%2Fb.example"
        let parsed = try NostrPairURI(parsing: uri(query: query))
        #expect(parsed.relays.map(\.absoluteString) == ["wss://a.example", "ws://b.example"])
    }

    @Test func ignoresUnknownParameters() throws {
        let query = "secret=\(Self.secret)&relay=wss%3A%2F%2Fr.example&future=whatever&v=1"
        let parsed = try NostrPairURI(parsing: uri(query: query))
        #expect(parsed.relays.count == 1)
    }

    @Test func acceptsUnencodedRelay() throws {
        let parsed = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)&relay=wss://r.example"))
        #expect(parsed.relays.map(\.absoluteString) == ["wss://r.example"])
    }

    @Test func acceptsUppercaseSchemeButNotUppercasePubkey() throws {
        // The scheme is case-insensitive per RFC 3986; the pubkey is not (NIP-AB).
        let parsed = try NostrPairURI(parsing: "NOSTRPAIR://\(Self.pubkey)?secret=\(Self.secret)&relay=wss://r.example")
        #expect(parsed.sourcePublicKey.hex == Self.pubkey)
    }

    // MARK: - Rejections

    @Test func rejectsOverLongURI() {
        let padding = String(repeating: "a", count: 2100)
        #expect(throws: NostrPairError.uriTooLong(2100 + "nostrpair://".count)) {
            _ = try NostrPairURI(parsing: "nostrpair://\(padding)")
        }
    }

    @Test func rejectsWrongScheme() {
        #expect(throws: NostrPairError.self) {
            _ = try NostrPairURI(parsing: "https://\(Self.pubkey)?secret=\(Self.secret)&relay=wss://r.example")
        }
    }

    @Test func rejectsMissingSchemeSeparator() {
        #expect(throws: NostrPairError.malformedURI) {
            _ = try NostrPairURI(parsing: "nostrpair-\(Self.pubkey)")
        }
    }

    @Test func rejectsUppercasePubkey() {
        #expect(throws: NostrPairError.invalidSourcePublicKey) {
            _ = try NostrPairURI(parsing: uri(pubkey: Self.pubkey.uppercased()))
        }
    }

    @Test func rejectsShortPubkey() {
        #expect(throws: NostrPairError.invalidSourcePublicKey) {
            _ = try NostrPairURI(parsing: uri(pubkey: "199e64ca"))
        }
    }

    @Test func rejectsMissingSecret() {
        #expect(throws: NostrPairError.missingSessionSecret) {
            _ = try NostrPairURI(parsing: uri(query: "relay=wss://r.example"))
        }
    }

    @Test func rejectsShortSecret() {
        #expect(throws: NostrPairError.invalidSessionSecret) {
            _ = try NostrPairURI(parsing: uri(query: "secret=deadbeef&relay=wss://r.example"))
        }
    }

    @Test func rejectsUppercaseSecret() {
        #expect(throws: NostrPairError.invalidSessionSecret) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret.uppercased())&relay=wss://r.example"))
        }
    }

    @Test func rejectsAllZeroSecret() {
        let zeros = String(repeating: "0", count: 64)
        #expect(throws: NostrPairError.zeroSessionSecret) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(zeros)&relay=wss://r.example"))
        }
    }

    @Test func rejectsMissingRelay() {
        #expect(throws: NostrPairError.missingRelay) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)"))
        }
    }

    @Test func rejectsNonWebSocketRelay() {
        #expect(throws: NostrPairError.missingRelay) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)&relay=https%3A%2F%2Fr.example"))
        }
    }

    @Test func rejectsUnsupportedVersion() {
        #expect(throws: NostrPairError.unsupportedVersion("2")) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)&relay=wss://r.example&v=2"))
        }
    }

    @Test func rejectsNonIntegerVersion() {
        #expect(throws: NostrPairError.unsupportedVersion("abc")) {
            _ = try NostrPairURI(parsing: uri(query: "secret=\(Self.secret)&relay=wss://r.example&v=abc"))
        }
    }
}
