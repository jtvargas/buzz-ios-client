import Foundation
@testable import NostrCore
import Testing

@Suite("Event signing")
struct SigningTests {
    @Test("A signed event is valid and self-consistent")
    func signedEventIsValid() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .textNote, content: "hello", tags: [["t", "buzz"]], with: key)
        #expect(event.hasValidID)
        #expect(event.isValid)
        #expect(event.pubkey == key.publicKey.hex)

        let signature = try #require(Data(hexString: event.sig))
        let identifier = try #require(Data(hexString: event.id))
        #expect(verifySchnorrSignature(
            signature: signature,
            message: identifier,
            publicKeyXOnly: key.publicKey.rawRepresentation
        ))
    }

    @Test("Tampering with any covered field breaks validity")
    func tamperingBreaksValidity() throws {
        let key = try PrivateKey()
        let event = try NostrEvent.signed(kind: .textNote, content: "original", with: key)

        let contentSwapped = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind, tags: event.tags, content: "swapped by a relay", sig: event.sig
        )
        #expect(!contentSwapped.hasValidID)
        #expect(!contentSwapped.isValid)

        let flippedID = String(event.id.dropLast()) + (event.id.hasSuffix("0") ? "1" : "0")
        let idSwapped = NostrEvent(
            id: flippedID, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind, tags: event.tags, content: event.content, sig: event.sig
        )
        #expect(!idSwapped.isValid)

        let flippedSig = String(event.sig.dropLast()) + (event.sig.hasSuffix("0") ? "1" : "0")
        let sigSwapped = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt,
            kind: event.kind, tags: event.tags, content: event.content, sig: flippedSig
        )
        // The covered fields are untouched, so the id still recomputes...
        #expect(sigSwapped.hasValidID)
        // ...but the signature no longer verifies.
        #expect(!sigSwapped.isValid)
    }

    @Test("Two signatures over the same event share an id but differ in bytes")
    func deterministicIDVaryingSignature() throws {
        let key = try PrivateKey()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try NostrEvent.signed(kind: .textNote, content: "same fields", createdAt: createdAt, with: key)
        let second = try NostrEvent.signed(kind: .textNote, content: "same fields", createdAt: createdAt, with: key)

        #expect(first.id == second.id)
        // Fresh auxiliary randomness per signature makes the bytes differ...
        #expect(first.sig != second.sig)
        // ...while both remain valid.
        #expect(first.isValid)
        #expect(second.isValid)
    }

    @Test("InMemorySigner produces valid events attributed to its key")
    func inMemorySignerRoundTrip() async throws {
        let key = try PrivateKey()
        let signer = InMemorySigner(key)

        let event = try await signer.sign(kind: .textNote, content: "via the signer")
        #expect(event.isValid)

        let publicKey = try await signer.publicKey()
        #expect(event.pubkey == publicKey.hex)
        #expect(publicKey == key.publicKey)
    }

    @Test("InMemorySigner refuses relay-signed kinds")
    func inMemorySignerRefusesRelaySignedKinds() async throws {
        let signer = try InMemorySigner()
        await #expect(throws: SigningError.relaySignedKind(.groupMetadata)) {
            try await signer.sign(kind: .groupMetadata, content: "should never publish")
        }
    }
}
