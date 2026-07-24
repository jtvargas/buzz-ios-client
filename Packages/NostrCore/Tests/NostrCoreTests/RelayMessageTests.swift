import Foundation
@testable import NostrCore
import Testing

@Suite("RelayMessage single-pass decode and frame tolerance")
struct RelayMessageTests {
    private let identity = TestSchnorrSigner.makeIdentity()

    /// Builds an `EVENT` frame the way a relay would: the type tag, the
    /// subscription id, and the event's own JSON spliced in unchanged. The event
    /// is serialized once here on the test side; the decode path under test does
    /// its own single pass.
    private func eventFrame(subscriptionID: String, event: NostrEvent) throws -> Data {
        let eventJSON = try #require(String(bytes: JSONEncoder().encode(event), encoding: .utf8))
        return Data(#"["EVENT","\#(subscriptionID)",\#(eventJSON)]"#.utf8)
    }

    private func decode(_ json: String) throws -> RelayMessage {
        try RelayMessage.decode(from: Data(json.utf8))
    }

    // MARK: - Round-trip of every variant

    @Test("An EVENT frame decodes to its subscription and a valid event")
    func decodesEvent() throws {
        let event = TestSchnorrSigner.signedEvent(
            kind: .channelMessage,
            content: "live message",
            tags: [["h", "group-1"]],
            with: identity
        )
        let decoded = try RelayMessage.decode(from: eventFrame(subscriptionID: "sub-1", event: event))
        #expect(decoded == .event(subscriptionID: "sub-1", event: event))
    }

    @Test("An accepted OK carries its trailing message")
    func decodesOKAccepted() throws {
        let decoded = try decode(#"["OK","abc123",true,"stored"]"#)
        #expect(decoded == .ok(eventID: "abc123", accepted: true, message: "stored"))
    }

    @Test("A rejected OK preserves its machine-readable message")
    func decodesOKRejected() throws {
        let decoded = try decode(#"["OK","abc123",false,"blocked: banned pubkey"]"#)
        #expect(decoded == .ok(eventID: "abc123", accepted: false, message: "blocked: banned pubkey"))
    }

    @Test("An OK with no trailing message decodes to an empty message")
    func decodesOKWithoutMessage() throws {
        let decoded = try decode(#"["OK","abc123",true]"#)
        #expect(decoded == .ok(eventID: "abc123", accepted: true, message: ""))
    }

    @Test("An EOSE frame decodes to its subscription")
    func decodesEOSE() throws {
        #expect(try decode(#"["EOSE","sub-1"]"#) == .eose(subscriptionID: "sub-1"))
    }

    @Test("A CLOSED frame carries its reason")
    func decodesClosed() throws {
        let decoded = try decode(#"["CLOSED","sub-1","auth-required: please authenticate"]"#)
        #expect(decoded == .closed(subscriptionID: "sub-1", message: "auth-required: please authenticate"))
    }

    @Test("A CLOSED frame with no reason decodes to an empty message")
    func decodesClosedWithoutMessage() throws {
        #expect(try decode(#"["CLOSED","sub-1"]"#) == .closed(subscriptionID: "sub-1", message: ""))
    }

    @Test("A NOTICE frame decodes its text")
    func decodesNotice() throws {
        #expect(try decode(#"["NOTICE","relay is restarting"]"#) == .notice(message: "relay is restarting"))
    }

    @Test("An AUTH challenge decodes")
    func decodesAuthChallenge() throws {
        #expect(try decode(#"["AUTH","challenge-token-xyz"]"#) == .authChallenge(challenge: "challenge-token-xyz"))
    }

    // MARK: - Malformed-frame fuzzing

    @Test(
        "Broken frames throw typed FrameErrors and never crash",
        arguments: [
            ("[]", RelayMessage.FrameError.empty),
            ("[123,\"sub\"]", .nonStringType),
            (#"["FOO","sub"]"#, .unknownType("FOO")),
            (#"["EVENT"]"#, .malformed(type: "EVENT")),
            (#"["EVENT","only-a-sub"]"#, .malformed(type: "EVENT")),
            (#"["EVENT","sub",{"not":"an event"}]"#, .malformed(type: "EVENT")),
            (#"["EVENT","sub","not-an-object"]"#, .malformed(type: "EVENT")),
            (#"["OK","id"]"#, .malformed(type: "OK")),
            (#"["OK","id","not-a-bool"]"#, .malformed(type: "OK")),
            (#"["EOSE"]"#, .malformed(type: "EOSE")),
            (#"["NOTICE"]"#, .malformed(type: "NOTICE")),
            (#"["AUTH"]"#, .malformed(type: "AUTH")),
            (#"["EVENT","sub""#, .notAnArray),
            (#"{"type":"EVENT"}"#, .notAnArray),
            ("not json at all", .notAnArray),
            ("", .notAnArray),
        ]
    )
    func brokenFramesThrow(json: String, expected: RelayMessage.FrameError) {
        #expect(throws: expected) {
            _ = try RelayMessage.decode(from: Data(json.utf8))
        }
    }

    @Test("A frame with trailing garbage past the modelled fields still decodes")
    func tolerantOfTrailingElements() throws {
        // Relays occasionally append fields a client does not model; the
        // positional reader takes what it needs and ignores the rest.
        let decoded = try decode(#"["EOSE","sub-1","unexpected-extra"]"#)
        #expect(decoded == .eose(subscriptionID: "sub-1"))
    }

    // MARK: - Volume and fidelity

    @Test("A large but valid EVENT frame decodes intact")
    func hugeValidFrame() throws {
        let content = String(repeating: "buzz ", count: 12000) // ~60 KB
        let event = TestSchnorrSigner.signedEvent(kind: .channelMessage, content: content, with: identity)
        let decoded = try RelayMessage.decode(from: eventFrame(subscriptionID: "sub-1", event: event))
        guard case let .event(_, decodedEvent) = decoded else {
            Issue.record("Expected an .event frame")
            return
        }
        #expect(decodedEvent.content == content)
        #expect(decodedEvent.isValid)
    }

    @Test("Single-pass decode preserves unknown kinds and non-ASCII byte-for-byte")
    func singlePassPreservesFidelity() throws {
        // If the event were bridged through a dictionary and re-encoded on the
        // way in, any lossy step would break the recomputed id. A valid id after
        // decode is the proof the event took one clean pass.
        let content = "日本語 café \u{1F680} /slashes/ & \"quotes\" \n\t control"
        let event = TestSchnorrSigner.signedEvent(
            kind: EventKind(rawValue: 987_654), // a kind this client does not name
            content: content,
            tags: [["t", "ünïcödé"], ["e", "ffff"]],
            with: identity
        )
        #expect(event.isValid)

        let decoded = try RelayMessage.decode(from: eventFrame(subscriptionID: "sub-1", event: event))
        guard case let .event(subscriptionID, decodedEvent) = decoded else {
            Issue.record("Expected an .event frame")
            return
        }
        #expect(subscriptionID == "sub-1")
        #expect(decodedEvent.kind.rawValue == 987_654)
        #expect(decodedEvent.content == content)
        #expect(decodedEvent.hasValidID)
        #expect(decodedEvent.isValid)
        #expect(decodedEvent == event)
    }
}
