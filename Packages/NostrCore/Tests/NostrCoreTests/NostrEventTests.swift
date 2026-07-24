import Foundation
@testable import NostrCore
import Testing

@Suite("NostrEvent validation, threading, and wire coding")
struct NostrEventTests {
    // MARK: - Signature and id validation

    @Test("A freshly signed event is fully valid")
    func signedEventIsValid() {
        let identity = TestSchnorrSigner.makeIdentity()
        let event = TestSchnorrSigner.signedEvent(
            kind: .textNote,
            content: "authentic message",
            tags: [["t", "buzz"]],
            with: identity
        )
        #expect(event.hasValidID)
        #expect(event.isValid)
        #expect(event.pubkey == identity.publicKeyHex)
    }

    @Test("Tampered content breaks id recomputation and validity")
    func tamperedContentFails() {
        let identity = TestSchnorrSigner.makeIdentity()
        let event = TestSchnorrSigner.signedEvent(kind: .textNote, content: "original", with: identity)
        let tampered = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: "swapped by a relay",
            sig: event.sig
        )
        #expect(!tampered.hasValidID)
        #expect(!tampered.isValid)
    }

    @Test("A tampered id fails")
    func tamperedIDFails() {
        let identity = TestSchnorrSigner.makeIdentity()
        let event = TestSchnorrSigner.signedEvent(kind: .textNote, content: "hello", with: identity)
        let flipped = String(event.id.dropLast()) + (event.id.hasSuffix("0") ? "1" : "0")
        let tampered = NostrEvent(
            id: flipped,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: event.sig
        )
        #expect(!tampered.hasValidID)
        #expect(!tampered.isValid)
    }

    @Test("A tampered signature fails while the id still matches")
    func tamperedSignatureFails() {
        let identity = TestSchnorrSigner.makeIdentity()
        let event = TestSchnorrSigner.signedEvent(kind: .textNote, content: "hello", with: identity)
        let flipped = String(event.sig.dropLast()) + (event.sig.hasSuffix("0") ? "1" : "0")
        let tampered = NostrEvent(
            id: event.id,
            pubkey: event.pubkey,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: flipped
        )
        // The fields are untouched, so the id still recomputes correctly...
        #expect(tampered.hasValidID)
        // ...but the signature no longer verifies.
        #expect(!tampered.isValid)
    }

    @Test("A signature from the wrong key fails")
    func wrongSignerFails() {
        let signer = TestSchnorrSigner.makeIdentity()
        let impostor = TestSchnorrSigner.makeIdentity()
        let event = TestSchnorrSigner.signedEvent(kind: .textNote, content: "hi", with: signer)
        let reattributed = NostrEvent(
            id: NostrEvent.computeID(
                pubkey: impostor.publicKeyHex,
                createdAt: event.createdAt,
                kind: event.kind,
                tags: event.tags,
                content: event.content
            ).hexString,
            pubkey: impostor.publicKeyHex,
            createdAt: event.createdAt,
            kind: event.kind,
            tags: event.tags,
            content: event.content,
            sig: event.sig
        )
        // id matches the impostor's fields, but the signature was made by signer.
        #expect(reattributed.hasValidID)
        #expect(!reattributed.isValid)
    }

    @Test("Malformed pubkey hex is rejected")
    func malformedPubkeyFails() {
        let event = NostrEvent(
            id: "00", pubkey: "not-hex", createdAt: 0, kind: .textNote,
            tags: [], content: "", sig: "00"
        )
        #expect(!event.isValid)
    }

    // MARK: - NIP-10 threading

    private let rootID = "1111111111111111111111111111111111111111111111111111111111111111"
    private let parentID = "2222222222222222222222222222222222222222222222222222222222222222"

    private func event(tags: [[String]]) -> NostrEvent {
        NostrEvent(id: "id", pubkey: "pk", createdAt: 0, kind: .channelMessage,
                   tags: tags, content: "", sig: "sig")
    }

    @Test("No e-tags means no reply")
    func noEventTags() {
        let reference = event(tags: [["h", "group"]]).threadReference
        #expect(reference.parentID == nil)
        #expect(reference.rootID == nil)
        #expect(!reference.isReply)
    }

    @Test("A lone root marker is not a reply")
    func loneRootIsNotReply() {
        let reference = event(tags: [["e", rootID, "", "root"]]).threadReference
        #expect(reference.parentID == nil)
        #expect(reference.rootID == nil)
        #expect(!reference.isReply)
    }

    @Test("An unmarked e-tag is not a reply")
    func unmarkedTagIsNotReply() {
        let reference = event(tags: [["e", rootID]]).threadReference
        #expect(!reference.isReply)
    }

    @Test("A reply straight to the opener uses the parent as root")
    func replyToOpener() {
        let reference = event(tags: [["e", rootID, "", "reply"]]).threadReference
        #expect(reference.parentID == rootID)
        #expect(reference.rootID == rootID)
        #expect(reference.isReply)
    }

    @Test("Root plus reply resolves both")
    func rootAndReply() {
        let tags = [["e", rootID, "", "root"], ["e", parentID, "", "reply"]]
        let reference = event(tags: tags).threadReference
        #expect(reference.parentID == parentID)
        #expect(reference.rootID == rootID)
    }

    @Test("The last reply marker wins")
    func lastReplyWins() {
        let first = "aaaa"
        let second = "bbbb"
        let tags = [["e", first, "", "reply"], ["e", second, "", "reply"]]
        let reference = event(tags: tags).threadReference
        #expect(reference.parentID == second)
    }

    @Test("A broadcast reply belongs in the channel, not only the thread")
    func broadcastReply() {
        let tags = [["e", parentID, "", "reply"], ["broadcast", "1"]]
        let broadcast = event(tags: tags)
        #expect(broadcast.threadReference.isReply)
        #expect(broadcast.isBroadcastReply)
        #expect(!broadcast.isThreadReply)
    }

    @Test("A plain reply is a thread reply")
    func plainReplyIsThreadReply() {
        let plain = event(tags: [["e", parentID, "", "reply"]])
        #expect(plain.isThreadReply)
        #expect(!plain.isBroadcastReply)
    }

    // MARK: - Tag accessors

    @Test("Tag accessors read first and all values")
    func tagAccessors() {
        let subject = event(tags: [
            ["h", "group-42"],
            ["d", "identifier"],
            ["p", "alice"],
            ["p", "bob"],
            ["e", "event-1"],
            ["broadcast"], // malformed single-element tag is ignored
        ])
        #expect(subject.groupID == "group-42")
        #expect(subject.addressableIdentifier == "identifier")
        #expect(subject.firstValue(forTag: "p") == "alice")
        #expect(subject.allValues(forTag: "p") == ["alice", "bob"])
        #expect(subject.referencedPubkeys == ["alice", "bob"])
        #expect(subject.referencedEventIDs == ["event-1"])
        #expect(subject.firstValue(forTag: "missing") == nil)
    }

    // MARK: - Wire coding

    @Test("Decodes wire JSON with created_at and a bare-integer kind")
    func decodesWireJSON() throws {
        let json = """
        {"id":"abc","pubkey":"def","created_at":1700000000,"kind":40002,\
        "tags":[["h","group1"],["e","ffff","","reply"]],"content":"hi","sig":"00"}
        """
        let event = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        #expect(event.createdAt == 1_700_000_000)
        #expect(event.kind == .richMessage)
        #expect(event.groupID == "group1")
        #expect(event.threadReference.parentID == "ffff")
    }

    @Test("Round-trips through JSON, unknown kinds surviving")
    func jsonRoundTrip() throws {
        let json = """
        {"id":"abc","pubkey":"def","created_at":42,"kind":987654,\
        "tags":[],"content":"x","sig":"00"}
        """
        let decoded = try JSONDecoder().decode(NostrEvent.self, from: Data(json.utf8))
        #expect(decoded.kind.rawValue == 987_654)

        let reEncoded = try JSONEncoder().encode(decoded)
        let encodedString = try #require(String(bytes: reEncoded, encoding: .utf8))
        #expect(encodedString.contains("\"created_at\":42"))
        #expect(encodedString.contains("\"kind\":987654"))

        let redecoded = try JSONDecoder().decode(NostrEvent.self, from: reEncoded)
        #expect(redecoded == decoded)
    }
}
