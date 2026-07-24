import Foundation
@testable import NostrCore
import Testing

@Suite("secp256k1 keys and BIP-340 signing")
struct KeysTests {
    /// One row of the official BIP-340 test-vector suite.
    ///
    /// `secretKey` is absent for verify-only rows. Signing with fresh auxiliary
    /// randomness cannot reproduce a vector's exact signature, so the signature is
    /// only ever checked in the verify direction.
    private struct BIP340Vector {
        let index: Int
        let secretKey: String?
        let publicKey: String
        let message: String
        let signature: String
        let verifies: Bool
    }

    /// Reproduced from the BIP-340 reference vectors (bitcoin/bips), lowercased to
    /// match this package's strict-lowercase hex coding.
    private static let vectors: [BIP340Vector] = [
        BIP340Vector(
            index: 0,
            secretKey: "0000000000000000000000000000000000000000000000000000000000000003",
            publicKey: "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",
            message: "0000000000000000000000000000000000000000000000000000000000000000",
            signature: "e907831f80848d1069a5371b402410364bdf1c5f8307b0084c55f1ce2dca8215"
                + "25f66a4a85ea8b71e482a74f382d2ce5ebeee8fdb2172f477df4900d310536c0",
            verifies: true
        ),
        BIP340Vector(
            index: 1,
            secretKey: "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef",
            publicKey: "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",
            message: "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
            signature: "6896bd60eeae296db48a229ff71dfe071bde413e6d43f917dc8dcf8c78de3341"
                + "8906d11ac976abccb20b091292bff4ea897efcb639ea871cfa95f6de339e4b0a",
            verifies: true
        ),
        BIP340Vector(
            index: 4,
            secretKey: nil,
            publicKey: "d69c3509bb99e412e68b0fe8544e72837dfa30746d8be2aa65975f29d22dc7b9",
            message: "4df3c3f68fcc83b27e9d42c90431a72499f17875c81a599b566c9889b9696703",
            signature: "00000000000000000000003b78ce563f89a0ed9414f5aa28ad0d96d6795f9c63"
                + "76afb1548af603b3eb45c9f8207dee1060cb71c04e80f593060b07d28308d7f4",
            verifies: true
        ),
        BIP340Vector(
            index: 7,
            secretKey: nil,
            publicKey: "dff1d77f2a671c5f36183726db2341be58feae1da2deced843240f7b502ba659",
            message: "243f6a8885a308d313198a2e03707344a4093822299f31d0082efa98ec4e6c89",
            signature: "1fa62e331edbc21c394792d2ab1100a7b432b013df3f6ff4f99fcb33e0e1515f"
                + "28890b3edb6e7189b630448b515ce4f8622a954cfe545735aaea5134fccdb2bd",
            verifies: false
        ),
    ]

    // MARK: - BIP-340 vectors

    @Test("BIP-340 vector: a secret key derives the specified x-only public key")
    func vectorPublicKeyDerivation() throws {
        for vector in Self.vectors {
            guard let secretHex = vector.secretKey else { continue }
            let key = try PrivateKey(hex: secretHex)
            #expect(key.publicKey.hex == vector.publicKey, "vector \(vector.index)")
        }
    }

    @Test("BIP-340 vector: verification matches the expected result")
    func vectorVerification() throws {
        for vector in Self.vectors {
            let signature = try #require(Data(hexString: vector.signature))
            let message = try #require(Data(hexString: vector.message))
            let publicKey = try #require(Data(hexString: vector.publicKey))
            let result = verifySchnorrSignature(signature: signature, message: message, publicKeyXOnly: publicKey)
            #expect(result == vector.verifies, "vector \(vector.index)")
        }
    }

    // MARK: - NIP-19 round-trips

    @Test("A private key round-trips through nsec")
    func nsecRoundTrip() throws {
        let key = try PrivateKey(hex: "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef")
        let nsec = key.nsec
        #expect(nsec.hasPrefix("nsec1"))
        let restored = try PrivateKey(nsec: nsec)
        #expect(restored.rawRepresentation == key.rawRepresentation)
    }

    @Test("A public key round-trips through npub")
    func npubRoundTrip() throws {
        let key = try PrivateKey(hex: "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef")
        let npub = key.publicKey.npub
        #expect(npub.hasPrefix("npub1"))
        let restored = try PublicKey(npub: npub)
        #expect(restored == key.publicKey)
        #expect(restored.hex == key.publicKey.hex)
    }

    // MARK: - Scalar validation

    @Test("A zero scalar is rejected")
    func zeroScalarRejected() {
        let zero = Data(repeating: 0, count: 32)
        #expect(throws: KeyError.invalidScalar) { try PrivateKey(rawRepresentation: zero) }
    }

    @Test("A scalar at or above the curve order is rejected")
    func oversizedScalarRejected() {
        // All-ones exceeds the secp256k1 group order n, so it is not a valid key.
        let allOnes = Data(repeating: 0xFF, count: 32)
        #expect(throws: KeyError.invalidScalar) { try PrivateKey(rawRepresentation: allOnes) }
    }

    @Test("A wrong-length scalar is rejected before any curve check")
    func wrongLengthRejected() {
        #expect(throws: KeyError.invalidLength(31)) {
            try PrivateKey(rawRepresentation: Data(repeating: 1, count: 31))
        }
    }

    @Test("Malformed hex is rejected")
    func malformedHexRejected() {
        #expect(throws: KeyError.invalidHex) { try PrivateKey(hex: "zz") }
        #expect(throws: KeyError.invalidHex) { try PrivateKey(hex: "abc") }
    }

    @Test("PublicKey rejects malformed input")
    func publicKeyRejectsMalformed() {
        #expect(PublicKey(hex: "zz") == nil)
        #expect(PublicKey(hex: "abcd") == nil)
        #expect(PublicKey(rawRepresentation: Data(repeating: 0, count: 31)) == nil)
    }

    @Test("Signing rejects a message that is not a 32-byte digest")
    func signRejectsNonDigest() throws {
        let key = try PrivateKey()
        #expect(throws: KeyError.invalidDigestLength(31)) {
            try key.signature(for: Data(repeating: 0, count: 31))
        }
    }

    // MARK: - Redaction

    @Test("A private key's description never leaks its bytes")
    func descriptionIsRedacted() throws {
        let secretHex = "b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfef"
        let key = try PrivateKey(hex: secretHex)
        #expect(key.description == "PrivateKey(redacted)")
        #expect(key.debugDescription == "PrivateKey(redacted)")
        #expect("\(key)" == "PrivateKey(redacted)")
        #expect(!key.description.contains(secretHex))
        #expect(!String(reflecting: key).contains(secretHex))
    }
}
