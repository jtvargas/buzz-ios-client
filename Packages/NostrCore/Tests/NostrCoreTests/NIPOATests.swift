import CryptoKit
import Foundation
@testable import NostrCore
import Testing

@Suite("NIP-OA owner attestation")
struct NIPOATests {
    // Official NIP-OA test vector.
    private let agentPubkey = "c6047f9441ed7d6d3045406e95c07cd85c778e4b8cef3ca7abac09b95c709ee5"
    private let ownerPubkey = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"
    private let conditions = "kind=1&created_at<1713957000"
    private let ownerSig =
        "8b7df2575caf0a108374f8471722b233c53f9ff827a8b0f91861966c3b9dd5cb"
            + "2e189eae9f49d72187674c2f5bd244145e10ff86c9f257ffe65a1ee5f108b369"

    private var validTag: [String] {
        ["auth", ownerPubkey, conditions, ownerSig]
    }

    // MARK: - Tag verification

    @Test("The official vector verifies")
    func officialVectorVerifies() {
        #expect(NIPOA.verify(authTag: validTag, eventPubkey: agentPubkey))
    }

    @Test("A tag with the wrong element count fails")
    func wrongElementCount() {
        let tooFew = ["auth", ownerPubkey, conditions]
        let tooMany = ["auth", ownerPubkey, conditions, ownerSig, "extra"]
        #expect(!NIPOA.verify(authTag: tooFew, eventPubkey: agentPubkey))
        #expect(!NIPOA.verify(authTag: tooMany, eventPubkey: agentPubkey))
    }

    @Test("A different preimage fails (conditions altered)")
    func alteredConditionsFail() {
        let tampered = ["auth", ownerPubkey, "kind=2&created_at<1713957000", ownerSig]
        #expect(!NIPOA.verify(authTag: tampered, eventPubkey: agentPubkey))
    }

    @Test("A different event pubkey fails (preimage binds the agent)")
    func differentEventPubkeyFails() {
        let otherAgent = "1111111111111111111111111111111111111111111111111111111111111111"
        #expect(!NIPOA.verify(authTag: validTag, eventPubkey: otherAgent))
    }

    @Test("A corrupted signature fails")
    func corruptedSignatureFails() {
        let flipped = String(ownerSig.dropLast()) + (ownerSig.hasSuffix("9") ? "8" : "9")
        let tampered = ["auth", ownerPubkey, conditions, flipped]
        #expect(!NIPOA.verify(authTag: tampered, eventPubkey: agentPubkey))
    }

    @Test("Self-attestation (owner equals author) fails")
    func selfAttestationFails() {
        #expect(!NIPOA.verify(authTag: validTag, eventPubkey: ownerPubkey))
    }

    @Test("Uppercase owner pubkey hex fails (lowercase required)")
    func uppercaseOwnerFails() {
        let tampered = ["auth", ownerPubkey.uppercased(), conditions, ownerSig]
        #expect(!NIPOA.verify(authTag: tampered, eventPubkey: agentPubkey))
    }

    // MARK: - Accessor

    @Test("The accessor returns the single auth tag")
    func accessorSingleTag() {
        let tags = [["h", "group"], validTag, ["t", "topic"]]
        #expect(NIPOA.authTag(in: tags) == validTag)
    }

    @Test("The accessor returns nil for zero or multiple auth tags")
    func accessorAmbiguous() {
        #expect(NIPOA.authTag(in: [["h", "group"]]) == nil)
        #expect(NIPOA.authTag(in: [validTag, validTag]) == nil)
    }

    // MARK: - End-to-end over a real event

    @Test("A valid event carrying an owner-signed tag exposes the owner")
    func verifiedOwnerOverValidEvent() {
        let owner = TestSchnorrSigner.makeIdentity()
        let agent = TestSchnorrSigner.makeIdentity()
        let clauses = "kind=1"
        let tag = makeAuthTag(owner: owner, agentPubkey: agent.publicKeyHex, conditions: clauses)
        let event = TestSchnorrSigner.signedEvent(
            kind: .textNote,
            content: "owner-attested agent event",
            tags: [tag],
            with: agent
        )

        #expect(event.isValid)
        #expect(NIPOA.verifiedOwnerPubkey(of: event) == owner.publicKeyHex)
    }

    @Test("A valid tag on an invalid event establishes no provenance")
    func invalidEventEstablishesNoProvenance() {
        let owner = TestSchnorrSigner.makeIdentity()
        let agent = TestSchnorrSigner.makeIdentity()
        let tag = makeAuthTag(owner: owner, agentPubkey: agent.publicKeyHex, conditions: "kind=1")
        let event = TestSchnorrSigner.signedEvent(
            kind: .textNote, content: "original", tags: [tag], with: agent
        )
        // Break the event without touching the (still owner-valid) auth tag.
        let corrupted = NostrEvent(
            id: event.id, pubkey: event.pubkey, createdAt: event.createdAt, kind: event.kind,
            tags: event.tags, content: "content swapped after signing", sig: event.sig
        )
        #expect(!corrupted.isValid)
        #expect(NIPOA.verifiedOwnerPubkey(of: corrupted) == nil)
    }

    /// Builds an owner-signed `auth` tag authorizing `agentPubkey` under
    /// `conditions`, following the NIP-OA preimage construction.
    private func makeAuthTag(
        owner: TestSchnorrSigner.Identity,
        agentPubkey: String,
        conditions: String
    ) -> [String] {
        let preimage = Data(("nostr:agent-auth:" + agentPubkey + ":" + conditions).utf8)
        let message = Data(SHA256.hash(data: preimage))
        let signature = TestSchnorrSigner.sign(message: message, with: owner)
        return ["auth", owner.publicKeyHex, conditions, signature.hexString]
    }
}
