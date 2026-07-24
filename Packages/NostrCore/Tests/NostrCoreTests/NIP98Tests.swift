import CryptoKit
import Foundation
@testable import NostrCore
import P256K
import Testing

@Suite("NIP-98 HTTP authentication")
struct NIP98Tests {
    /// A fixed, valid secp256k1 secret (scalar 1) for deterministic fixtures.
    static let fixedSecretHex = "0000000000000000000000000000000000000000000000000000000000000001"

    // MARK: - Tags

    @Test("The authorization event pins the request URL verbatim in the u tag")
    func urlTagIsExact() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query?scope=live"))
        let event = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        #expect(event.kind == .httpAuthentication)
        #expect(event.content.isEmpty)
        #expect(event.firstValue(forTag: "u") == "https://relay.buzz.example/query?scope=live")
    }

    @Test("The method tag is upper-cased regardless of the caller's casing")
    func methodTagIsUpperCased() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let event = try await NIP98.authorizationEvent(url: url, method: "post", signer: signer)

        #expect(event.firstValue(forTag: "method") == "POST")
    }

    @Test("The payload tag is the SHA-256 hex of the request body")
    func payloadTagHashesTheBody() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let body = Data("{\"kinds\":[9],\"#h\":[\"buzz\"]}".utf8)
        let event = try await NIP98.authorizationEvent(url: url, method: "POST", body: body, signer: signer)

        let expected = Data(SHA256.hash(data: body)).hexString
        #expect(event.firstValue(forTag: "payload") == expected)
    }

    @Test("An empty body still carries the payload tag: the hash of zero bytes")
    func payloadTagPresentForEmptyBody() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let event = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        // SHA-256 of the empty input — a fixed, well-known digest.
        let emptyDigest = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        #expect(event.firstValue(forTag: "payload") == emptyDigest)
        #expect(Data(SHA256.hash(data: Data())).hexString == emptyDigest)
    }

    @Test("Each event draws a fresh, non-empty nonce")
    func nonceIsFreshPerEvent() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let first = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)
        let second = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        let firstNonce = try #require(first.firstValue(forTag: "nonce"))
        let secondNonce = try #require(second.firstValue(forTag: "nonce"))
        #expect(!firstNonce.isEmpty)
        #expect(!secondNonce.isEmpty)
        #expect(firstNonce != secondNonce)
        // A fresh nonce means even identical requests get distinct event ids.
        #expect(first.id != second.id)
    }

    // MARK: - Header format

    @Test("The header carries the Nostr scheme over strict base64 of a valid event")
    func headerFormatDecodesToValidEvent() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let body = Data("payload bytes".utf8)
        let header = try await NIP98.authorizationHeader(url: url, method: "POST", body: body, signer: signer)

        #expect(header.hasPrefix("Nostr "))
        let encoded = String(header.dropFirst("Nostr ".count))
        let json = try #require(Data(base64Encoded: encoded), "the payload must be strict base64")

        let event = try JSONDecoder().decode(NostrEvent.self, from: json)
        #expect(event.kind == .httpAuthentication)
        #expect(event.isValid)
        let publicKey = try await signer.publicKey()
        #expect(event.pubkey == publicKey.hex)
    }

    // MARK: - Validation

    @Test("A freshly built event validates against its own request")
    func validateAcceptsMatchingEvent() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let body = Data("body".utf8)
        let event = try await NIP98.authorizationEvent(url: url, method: "POST", body: body, signer: signer)

        #expect(NIP98.validate(event: event, url: url, method: "POST", body: body))
        // Casing on the method is normalised on both sides.
        #expect(NIP98.validate(event: event, url: url, method: "post", body: body))
    }

    @Test("A validly built header validates end to end")
    func validateAcceptsMatchingHeader() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let header = try await NIP98.authorizationHeader(url: url, method: "GET", signer: signer)

        #expect(NIP98.validate(header: header, url: url, method: "GET"))
    }

    @Test("Validation rejects a mismatched method")
    func validateRejectsWrongMethod() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let event = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        #expect(!NIP98.validate(event: event, url: url, method: "POST"))
    }

    @Test("Validation rejects a mismatched URL")
    func validateRejectsWrongURL() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let other = try #require(URL(string: "https://relay.buzz.example/upload"))
        let event = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        #expect(!NIP98.validate(event: event, url: other, method: "GET"))
    }

    @Test("Validation rejects a body that does not match the payload hash")
    func validateRejectsWrongPayloadHash() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let signedBody = Data("the body that was signed".utf8)
        let event = try await NIP98.authorizationEvent(url: url, method: "POST", body: signedBody, signer: signer)

        let tamperedBody = Data("a different body on the wire".utf8)
        #expect(!NIP98.validate(event: event, url: url, method: "POST", body: tamperedBody))
    }

    @Test("Validation rejects a timestamp outside the acceptance window")
    func validateRejectsStaleTimestamp() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let stamped = Date(timeIntervalSince1970: 1_700_000_000)
        let event = try await NIP98.authorizationEvent(
            url: url,
            method: "GET",
            body: Data(),
            generated: NIP98.GeneratedInputs(nonce: UUID().uuidString, createdAt: stamped),
            signer: signer
        )

        // Well within the window.
        #expect(NIP98.validate(event: event, url: url, method: "GET", now: stamped.addingTimeInterval(30)))
        // Just outside a 60-second window, on both sides.
        #expect(!NIP98.validate(event: event, url: url, method: "GET", now: stamped.addingTimeInterval(61)))
        #expect(!NIP98.validate(event: event, url: url, method: "GET", now: stamped.addingTimeInterval(-61)))
    }

    @Test("Validation rejects an event whose signature does not verify")
    func validateRejectsInvalidSignature() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let event = try await NIP98.authorizationEvent(url: url, method: "GET", signer: signer)

        let flippedSig = String(event.sig.dropLast()) + (event.sig.hasSuffix("0") ? "1" : "0")
        let tampered = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: flippedSig
        )
        #expect(!NIP98.validate(event: tampered, url: url, method: "GET"))
    }

    @Test("Validation rejects an event of the wrong kind")
    func validateRejectsWrongKind() async throws {
        let signer = try InMemorySigner()
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        // A validly signed event carrying the right tags but the wrong kind.
        let event = try await signer.sign(
            kind: .textNote,
            content: "",
            tags: [
                ["u", url.absoluteString],
                ["method", "GET"],
                ["payload", Data(SHA256.hash(data: Data())).hexString],
                ["nonce", UUID().uuidString],
            ]
        )
        #expect(event.isValid)
        #expect(!NIP98.validate(event: event, url: url, method: "GET"))
    }

    @Test("A malformed header is rejected rather than throwing")
    func validateRejectsMalformedHeader() throws {
        let target = try #require(URL(string: "https://relay.buzz.example/query"))
        // Wrong scheme, non-base64 payload, and base64 of a non-event JSON.
        #expect(!NIP98.validate(header: "Bearer abc", url: target, method: "GET"))
        #expect(!NIP98.validate(header: "Nostr not-base64!!", url: target, method: "GET"))
        let notAnEvent = "Nostr " + Data("{}".utf8).base64EncodedString()
        #expect(!NIP98.validate(header: notAnEvent, url: target, method: "GET"))
    }

    // MARK: - Wire-format pin

    /// The exact header for a fixed key (secret scalar 1), method, URL, body,
    /// nonce, and timestamp. Signatures on the production path use fresh BIP-340
    /// auxiliary randomness and so vary per call; `DeterministicSigner` signs with
    /// all-zero auxiliary randomness (permitted by BIP-340) so the encoded event
    /// is reproducible and can be pinned here. Regenerate this constant only when
    /// the encoding itself is intended to change.
    static let pinnedHeader =
        "Nostr eyJjb250ZW50IjoiIiwiY3JlYXRlZF9hdCI6MTcwMDAwMDAwMCwiaWQiOiIzMTg1ZDA2ZTU0" +
        "OTQ0NzhkYWE4MGJjZmI2NzE1ZWMzYTVmNjUzZGY2ZDhmZTdmYzFhMGQ1ODllOGZlODYwZjZj" +
        "Iiwia2luZCI6MjcyMzUsInB1YmtleSI6Ijc5YmU2NjdlZjlkY2JiYWM1NWEwNjI5NWNlODcw" +
        "YjA3MDI5YmZjZGIyZGNlMjhkOTU5ZjI4MTViMTZmODE3OTgiLCJzaWciOiI4ZGZiZjYyZjIy" +
        "M2ZmZGVjYTdiNzAyM2E4OTgwZGY3NDAyYWNmYzViMDgzOTI0ZDlmYjkzZDAxNmE1OGVmZDZm" +
        "MzE5MjRjMTQzNzAzZjlhZjM3ODgzMjM3MzQzYWQ2ZTY4MDI2NWE0MjI2ZGY1Y2EwOTk1OTIx" +
        "NDk1MDcxYjdhNiIsInRhZ3MiOltbInUiLCJodHRwczovL3JlbGF5LmJ1enouZXhhbXBsZS9x" +
        "dWVyeSJdLFsibWV0aG9kIiwiUE9TVCJdLFsicGF5bG9hZCIsIjIwYWYwMGRhOWExZmEwNDll" +
        "MWUxZmJiNzI1MWU1ZjNlZjgyY2UzMTIxN2JhM2U3MTUzZGJmMzljNWFjNTQxMGMiXSxbIm5v" +
        "bmNlIiwiMTExMTExMTEtMTExMS00MTExLTgxMTEtMTExMTExMTExMTExIl1dfQ=="

    @Test("The encoded header is byte-for-byte stable for fixed inputs")
    func headerWireFormatIsPinned() async throws {
        let key = try PrivateKey(hex: Self.fixedSecretHex)
        let signer = DeterministicSigner(key: key)
        let url = try #require(URL(string: "https://relay.buzz.example/query"))
        let body = Data("{\"kinds\":[9]}".utf8)
        let nonce = "11111111-1111-4111-8111-111111111111"
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)

        let header = try await NIP98.authorizationHeader(
            url: url,
            method: "POST",
            body: body,
            generated: NIP98.GeneratedInputs(nonce: nonce, createdAt: createdAt),
            signer: signer
        )

        #expect(header == Self.pinnedHeader)
        // The pinned bytes must also be a genuinely valid, self-consistent event.
        #expect(NIP98.validate(header: header, url: url, method: "POST", body: body, now: createdAt))
    }
}

/// A signer with reproducible output, for pinning the exact wire format.
///
/// The production signer draws fresh BIP-340 auxiliary randomness per signature,
/// so its bytes vary run to run. This double signs with all-zero auxiliary
/// randomness — which BIP-340 permits — so a given key and message always yield
/// the same signature, letting a test hard-code the resulting header.
private struct DeterministicSigner: EventSigner {
    let key: PrivateKey

    func publicKey() async throws -> PublicKey {
        key.publicKey
    }

    func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent {
        let pubkey = key.publicKey.hex
        let createdAtUnix = Int64(createdAt.timeIntervalSince1970)
        let idBytes = NostrEvent.computeID(
            pubkey: pubkey,
            createdAt: createdAtUnix,
            kind: kind,
            tags: tags,
            content: content
        )
        let backing = try P256K.Schnorr.PrivateKey(dataRepresentation: key.rawRepresentation)
        var message = Array(idBytes)
        var auxiliary = [UInt8](repeating: 0, count: 32)
        let signature = try auxiliary.withUnsafeMutableBytes { buffer in
            try backing.signature(message: &message, auxiliaryRand: buffer.baseAddress, strict: true)
        }
        return NostrEvent(
            id: idBytes.hexString,
            pubkey: pubkey,
            createdAt: createdAtUnix,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.dataRepresentation.hexString
        )
    }
}
