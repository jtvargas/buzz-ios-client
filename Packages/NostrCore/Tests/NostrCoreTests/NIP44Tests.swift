import CryptoKit
import Foundation
@testable import NostrCore
import Testing

/// The official NIP-44 v2 vector suite (paulmillr/nip44), vendored verbatim.
///
/// Every conforming implementation tests against this file: a payload NostrCore
/// produces must decrypt in Buzz's other clients, and theirs must decrypt here.
/// The JSON uses snake_case keys, mapped to camelCase properties by the decoder.
enum NIP44Vectors {
    struct File: Decodable {
        let v2: Version2
    }

    struct Version2: Decodable {
        let valid: Valid
        let invalid: Invalid
    }

    struct Valid: Decodable {
        let getConversationKey: [ConversationKeyVector]
        let getMessageKeys: MessageKeysVector
        let calcPaddedLen: [[Int]]
        let encryptDecrypt: [EncryptDecryptVector]
        let encryptDecryptLongMsg: [LongMessageVector]
    }

    struct Invalid: Decodable {
        let getConversationKey: [InvalidConversationKeyVector]
        let decrypt: [InvalidDecryptVector]
        let encryptMsgLengths: [Int]
    }

    struct ConversationKeyVector: Decodable {
        let sec1: String
        let pub2: String
        let conversationKey: String
    }

    struct MessageKeysVector: Decodable {
        let conversationKey: String
        let keys: [MessageKeyEntry]
    }

    struct MessageKeyEntry: Decodable {
        let nonce: String
        let chachaKey: String
        let chachaNonce: String
        let hmacKey: String
    }

    struct EncryptDecryptVector: Decodable {
        let sec1: String
        let sec2: String
        let conversationKey: String
        let nonce: String
        let plaintext: String
        let payload: String
    }

    struct LongMessageVector: Decodable {
        let conversationKey: String
        let nonce: String
        let pattern: String
        let `repeat`: Int
        let plaintextSha256: String
        let payloadSha256: String
    }

    struct InvalidConversationKeyVector: Decodable {
        let sec1: String
        let pub2: String
        let note: String?
    }

    struct InvalidDecryptVector: Decodable {
        let conversationKey: String
        let payload: String
        let note: String?
    }

    static func load() throws -> Version2 {
        let url = try #require(
            Bundle.module.url(forResource: "nip44.vectors", withExtension: "json"),
            "the NIP-44 vector resource must be bundled with the test target"
        )
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(File.self, from: Data(contentsOf: url)).v2
    }
}

@Suite("NIP-44 v2 official vectors")
struct NIP44VectorTests {
    @Test("derives every valid conversation key")
    func conversationKeys() throws {
        let vectors = try NIP44Vectors.load().valid.getConversationKey
        #expect(vectors.count == 35)
        for vector in vectors {
            let key = try PrivateKey(hex: vector.sec1)
            let peer = try #require(PublicKey(hex: vector.pub2))
            let derived = try NIP44.conversationKey(privateKey: key, peer: peer)
            #expect(derived.hexString == vector.conversationKey)
        }
    }

    @Test("conversation keys are symmetric across both parties")
    func symmetry() throws {
        let vector = try #require(NIP44Vectors.load().valid.encryptDecrypt.first)
        let alice = try PrivateKey(hex: vector.sec1)
        let bob = try PrivateKey(hex: vector.sec2)

        let fromAlice = try NIP44.conversationKey(privateKey: alice, peer: bob.publicKey)
        let fromBob = try NIP44.conversationKey(privateKey: bob, peer: alice.publicKey)
        #expect(fromAlice == fromBob)
        #expect(fromAlice.hexString == vector.conversationKey)
    }

    @Test("derives every set of per-message keys")
    func messageKeys() throws {
        let group = try NIP44Vectors.load().valid.getMessageKeys
        let conversationKey = try #require(Data(hexString: group.conversationKey))
        #expect(group.keys.count == 32)

        for vector in group.keys {
            let nonce = try #require(Data(hexString: vector.nonce))
            let keys = NIP44.messageKeys(conversationKey: conversationKey, nonce: nonce)
            #expect(keys.chachaKey.hexString == vector.chachaKey)
            #expect(keys.chachaNonce.hexString == vector.chachaNonce)
            #expect(keys.hmacKey.hexString == vector.hmacKey)
        }
    }

    @Test("computes every padded length")
    func paddedLengths() throws {
        let pairs = try NIP44Vectors.load().valid.calcPaddedLen
        #expect(pairs.count == 24)
        for pair in pairs {
            #expect(NIP44.paddedLength(pair[0]) == pair[1], "padding for \(pair[0])")
        }
    }

    @Test("produces byte-identical payloads with the vector nonces")
    func encryptMatchesVectors() throws {
        // Byte-identical, not merely round-tripping: any divergence means payloads
        // other clients cannot read, or subtly weaker crypto.
        let vectors = try NIP44Vectors.load().valid.encryptDecrypt
        #expect(vectors.count == 10)
        for vector in vectors {
            let key = try #require(Data(hexString: vector.conversationKey))
            let nonce = try #require(Data(hexString: vector.nonce))
            let payload = try NIP44.encrypt(vector.plaintext, conversationKey: key, nonce: nonce)
            #expect(payload == vector.payload)
        }
    }

    @Test("decrypts every vector payload")
    func decryptMatchesVectors() throws {
        for vector in try NIP44Vectors.load().valid.encryptDecrypt {
            let key = try #require(Data(hexString: vector.conversationKey))
            let plaintext = try NIP44.decrypt(vector.payload, conversationKey: key)
            #expect(plaintext == vector.plaintext)
        }
    }

    @Test("round-trips the long-message vectors by content hash")
    func longMessages() throws {
        let vectors = try NIP44Vectors.load().valid.encryptDecryptLongMsg
        #expect(vectors.count == 3)
        for vector in vectors {
            let key = try #require(Data(hexString: vector.conversationKey))
            let nonce = try #require(Data(hexString: vector.nonce))
            let plaintext = String(repeating: vector.pattern, count: vector.repeat)

            let plaintextDigest = SHA256.hash(data: Data(plaintext.utf8))
            #expect(Data(plaintextDigest).hexString == vector.plaintextSha256)

            let payload = try NIP44.encrypt(plaintext, conversationKey: key, nonce: nonce)
            let payloadDigest = SHA256.hash(data: Data(payload.utf8))
            #expect(Data(payloadDigest).hexString == vector.payloadSha256)

            #expect(try NIP44.decrypt(payload, conversationKey: key) == plaintext)
        }
    }

    @Test("rejects every invalid conversation-key input")
    func rejectsInvalidConversationKeys() throws {
        let vectors = try NIP44Vectors.load().invalid.getConversationKey
        #expect(vectors.count == 8)
        for vector in vectors {
            // The failure may surface at private-key validation (bad scalar) or at
            // key agreement (peer point not on the curve); either is acceptable.
            #expect(throws: (any Error).self, "\(vector.note ?? "invalid conversation key")") {
                let key = try PrivateKey(hex: vector.sec1)
                guard let peer = PublicKey(hex: vector.pub2) else { throw NIP44.Failure.keyAgreementFailed }
                _ = try NIP44.conversationKey(privateKey: key, peer: peer)
            }
        }
    }

    @Test("rejects every invalid decrypt payload")
    func rejectsInvalidDecrypts() throws {
        let vectors = try NIP44Vectors.load().invalid.decrypt
        #expect(vectors.count == 12)
        for vector in vectors {
            let key = try #require(Data(hexString: vector.conversationKey))
            #expect(throws: NIP44.Failure.self, "\(vector.note ?? "invalid payload")") {
                _ = try NIP44.decrypt(vector.payload, conversationKey: key)
            }
        }
    }

    @Test("rejects every out-of-bounds plaintext length")
    func rejectsInvalidPlaintextLengths() throws {
        let lengths = try NIP44Vectors.load().invalid.encryptMsgLengths
        let key = Data(repeating: 0x11, count: 32)
        for length in lengths {
            let plaintext = String(repeating: "a", count: length)
            #expect(throws: NIP44.Failure.self, "length \(length)") {
                _ = try NIP44.encrypt(plaintext, conversationKey: key)
            }
        }
    }
}

@Suite("NIP-44 v2 behaviour")
struct NIP44BehaviourTests {
    private func conversationKey() throws -> Data {
        let alice = try PrivateKey()
        let bob = try PrivateKey()
        return try NIP44.conversationKey(privateKey: alice, peer: bob.publicKey)
    }

    @Test("round-trips with a fresh random nonce")
    func roundTrips() throws {
        let key = try conversationKey()
        let message = "the gutters breathe at 20 🐝 — עברית, العربية, 中文"
        let payload = try NIP44.encrypt(message, conversationKey: key)
        #expect(try NIP44.decrypt(payload, conversationKey: key) == message)
    }

    @Test("two encryptions of the same message differ but both decrypt")
    func freshNoncePerEncryption() throws {
        let key = try conversationKey()
        let first = try NIP44.encrypt("same message", conversationKey: key)
        let second = try NIP44.encrypt("same message", conversationKey: key)
        #expect(first != second)
        #expect(try NIP44.decrypt(first, conversationKey: key) == "same message")
        #expect(try NIP44.decrypt(second, conversationKey: key) == "same message")
    }

    @Test("a tampered payload fails authentication")
    func tamperingFailsAuthentication() throws {
        let key = try conversationKey()
        let payload = try NIP44.encrypt("original", conversationKey: key)

        var bytes = try #require(Data(base64Encoded: payload))
        bytes[bytes.count / 2] ^= 0x01
        #expect(throws: NIP44.Failure.authenticationFailed) {
            _ = try NIP44.decrypt(bytes.base64EncodedString(), conversationKey: key)
        }
    }

    @Test("the wrong conversation key fails authentication, not garbage output")
    func wrongKeyFailsAuthentication() throws {
        let senderKey = try conversationKey()
        let receiverKey = try conversationKey()
        let payload = try NIP44.encrypt("secret", conversationKey: senderKey)
        #expect(throws: NIP44.Failure.authenticationFailed) {
            _ = try NIP44.decrypt(payload, conversationKey: receiverKey)
        }
    }

    @Test("empty and oversized plaintexts are rejected distinctly")
    func plaintextBounds() throws {
        let key = try conversationKey()
        #expect(throws: NIP44.Failure.emptyPlaintext) {
            _ = try NIP44.encrypt("", conversationKey: key)
        }
        #expect(throws: NIP44.Failure.plaintextTooLong(65536)) {
            _ = try NIP44.encrypt(String(repeating: "a", count: 65536), conversationKey: key)
        }
    }

    @Test("a '#'-prefixed payload is surfaced as an unsupported version")
    func futureVersionMarker() throws {
        let key = try conversationKey()
        #expect(throws: NIP44.Failure.unsupportedVersion(0)) {
            _ = try NIP44.decrypt("#a-future-scheme", conversationKey: key)
        }
    }

    @Test("garbage is malformed, not an unsupported version")
    func garbageIsMalformed() throws {
        let key = try conversationKey()
        #expect(throws: NIP44.Failure.malformedPayload) {
            _ = try NIP44.decrypt("not valid base64 !!!", conversationKey: key)
        }
    }
}
