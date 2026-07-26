@testable import BuzzKit
import Foundation
import NostrCore
import Testing

// MARK: - Response parsing

/// The `response:`-prefixed command answer, parsed in isolation. Pure, so no socket.
@Suite("SyncEngine DM response parsing")
struct DirectMessageResponseParsingTests {
    @Test("a well-formed payload yields the channel id and the created flag")
    func wellFormed() throws {
        let parsed = try SyncEngine.parseOpenResponse(
            #"response:{"channel_id":"9f1c-dm","created":true}"#
        )
        #expect(parsed == DirectMessageOpen(channelID: "9f1c-dm", wasCreated: true))
    }

    @Test("`created: false` parses as a success, not a failure")
    func createdFalseIsSuccess() throws {
        let parsed = try SyncEngine.parseOpenResponse(
            #"response:{"channel_id":"9f1c-dm","created":false}"#
        )
        #expect(parsed == DirectMessageOpen(channelID: "9f1c-dm", wasCreated: false))
    }

    @Test("`created` is optional, absent meaning not-created")
    func createdIsTolerated() throws {
        // The channel id is the only field a caller cannot proceed without, and the
        // read-back runs whatever the flag says — so a relay that omits it is served,
        // not refused.
        let parsed = try SyncEngine.parseOpenResponse(#"response:{"channel_id":"9f1c-dm"}"#)
        #expect(parsed == DirectMessageOpen(channelID: "9f1c-dm", wasCreated: false))
    }

    @Test(
        "anything that is not a prefixed, channel-id-carrying payload is malformed",
        arguments: [
            "", // an accepted command with no message at all
            "stored", // a plain human acknowledgement
            #"{"channel_id":"9f1c-dm","created":true}"#, // JSON, but no `response:` prefix
            "response:", // the prefix with nothing behind it
            "response:not json at all",
            #"response:{"created":true}"#, // no channel id
            #"response:{"channel_id":"","created":true}"#, // an empty channel id is unusable
            #"response:{"channel_id":42}"#, // wrong type
        ]
    )
    func malformed(message: String) throws {
        #expect(throws: DirectMessageError.malformedResponse(message)) {
            try SyncEngine.parseOpenResponse(message)
        }
    }
}

// MARK: - Peer normalisation

/// Peer identifiers accepted, normalised, and refused before the wire.
@Suite("SyncEngine DM peer normalisation")
struct DirectMessagePeerNormalisationTests {
    @Test("hex is lowercased and trimmed")
    func hexIsNormalised() throws {
        let key = try PrivateKey().publicKey
        #expect(try SyncEngine.normalizedPubkey("  \(key.hex.uppercased())\n") == key.hex)
        #expect(try SyncEngine.normalizedPubkey(key.hex) == key.hex)
    }

    @Test("a NIP-19 npub is decoded to hex")
    func npubIsDecoded() throws {
        let key = try PrivateKey().publicKey
        #expect(try SyncEngine.normalizedPubkey(key.npub) == key.hex)
        #expect(try SyncEngine.normalizedPubkey(" \(key.npub) ") == key.hex)
    }

    @Test(
        "anything that is not a 32-byte key is refused",
        arguments: [
            "",
            "not-a-pubkey",
            "abcd", // hex, but not 32 bytes
            String(repeating: "a", count: 63), // one nibble short
            String(repeating: "a", count: 65),
            String(repeating: "z", count: 64), // right length, not hex
            "npub1notrealbech32",
        ]
    )
    func refused(raw: String) throws {
        #expect(throws: DirectMessageError.invalidPeerPubkey(raw)) {
            try SyncEngine.normalizedPubkey(raw)
        }
    }
}
