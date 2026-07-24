import Foundation
@testable import NostrCore
import Testing

@Suite("ClientMessage NIP-01/NIP-42 frame coding")
struct ClientMessageTests {
    private let identity = TestSchnorrSigner.makeIdentity()

    /// The frame's leading type tag, read back through the decoder.
    private func typeTag(of data: Data) throws -> String {
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        return try #require(array.first as? String)
    }

    @Test("An EVENT frame round-trips and keeps its event intact")
    func eventRoundTrip() throws {
        let event = TestSchnorrSigner.signedEvent(
            kind: .channelMessage,
            content: "hello relay",
            tags: [["h", "group-1"]],
            with: identity
        )
        let message = ClientMessage.event(event)
        let data = try message.encoded()

        #expect(try typeTag(of: data) == "EVENT")
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
        #expect(decoded == message)
        if case let .event(decodedEvent) = decoded {
            #expect(decodedEvent.isValid)
        } else {
            Issue.record("Expected an .event frame")
        }
    }

    @Test("An AUTH frame round-trips as its own type tag")
    func authRoundTrip() throws {
        let event = TestSchnorrSigner.signedEvent(
            kind: .clientAuthentication,
            content: "",
            tags: [["relay", "wss://relay.example"], ["challenge", "abc123"]],
            with: identity
        )
        let message = ClientMessage.auth(event)
        let data = try message.encoded()

        #expect(try typeTag(of: data) == "AUTH")
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == message)
    }

    @Test("A CLOSE frame round-trips")
    func closeRoundTrip() throws {
        let message = ClientMessage.close(subscriptionID: "sub-42")
        let data = try message.encoded()

        #expect(try typeTag(of: data) == "CLOSE")
        #expect(try JSONDecoder().decode(ClientMessage.self, from: data) == message)
    }

    @Test("A REQ frame round-trips with multiple filters")
    func reqRoundTrip() throws {
        let filters = [
            Filter(kinds: [.channelMessage], limit: 100).inGroup("group-1"),
            Filter(kinds: [.giftWrap]).taggingPubkey(identity.publicKeyHex),
        ]
        let message = ClientMessage.req(subscriptionID: "live-1", filters: filters)
        let data = try message.encoded()

        #expect(try typeTag(of: data) == "REQ")
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: data)
        #expect(decoded == message)
    }

    @Test("A REQ frame lays out as [type, id, filter, filter, ...]")
    func reqArrayLayout() throws {
        let message = ClientMessage.req(
            subscriptionID: "s1",
            filters: [Filter(kinds: [.textNote]), Filter(kinds: [.reaction])]
        )
        let data = try message.encoded()
        let array = try #require(try JSONSerialization.jsonObject(with: data) as? [Any])
        #expect(array.count == 4)
        #expect(array[0] as? String == "REQ")
        #expect(array[1] as? String == "s1")
        #expect(array[2] is [String: Any])
        #expect(array[3] is [String: Any])
    }

    @Test("A REQ with no filters still encodes the id")
    func reqWithoutFilters() throws {
        let message = ClientMessage.req(subscriptionID: "s1", filters: [])
        let decoded = try JSONDecoder().decode(ClientMessage.self, from: message.encoded())
        #expect(decoded == message)
    }

    @Test("An unrecognised client frame type is rejected on decode")
    func unknownTypeThrows() {
        let data = Data(#"["MYSTERY","x"]"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(ClientMessage.self, from: data)
        }
    }
}
