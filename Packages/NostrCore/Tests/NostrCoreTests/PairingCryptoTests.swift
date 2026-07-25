import Foundation
@testable import NostrCore
import Testing

/// Validates ``PairingCrypto`` against NIP-AB's published test vectors
/// (crates/buzz-core/src/pairing/NIP-AB.md §Test Vectors). A pass proves this
/// client derives the same session id, SAS, and transcript hash a Buzz desktop
/// does — the cross-implementation agreement the pairing handshake depends on.
@Suite struct PairingCryptoTests {
    // The canonical vectors, verbatim.
    static let sessionSecret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
    static let sourcePrivkey = "7f4c11a9c9d1e3b5a7f2e4d6c8b0a2f4e6d8c0b2a4f6e8d0c2b4a6f8e0d2c4b5"
    static let sourcePubkey = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"
    static let targetPrivkey = "3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b"
    static let targetPubkey = "89a9fa762105d0aee2b19678246fe7b823aabbc4f4bf691a1ce8a70fcd36d6e4"
    static let sessionID = "fb357d0f8e8d5a5ba3b2a91cb18c119e1567b07ffa38cdebb73e68df78f5a380"
    static let ecdhShared = "9b4b6d6990713d89d6d9982e506ee1bbcde6f05c54d9d2978696e8a7274d4408"
    static let sasInput = "e8b03a329f3a0ac37fe7fbe929171e14b72812be67e33c5d6e193543c41798d3"
    static let sasCode = "863346"
    static let transcriptHash = "d662818ff8911fc60a2d025f8b8b4756107104e85888dd202d28db5ca2cf28d3"

    private func data(_ hex: String) -> Data { Data(hexString: hex)! }

    @Test func sourcePrivateKeyDerivesVectorPublicKey() throws {
        let key = try PrivateKey(hex: Self.sourcePrivkey)
        #expect(key.publicKey.hex == Self.sourcePubkey)
    }

    @Test func targetPrivateKeyDerivesVectorPublicKey() throws {
        let key = try PrivateKey(hex: Self.targetPrivkey)
        #expect(key.publicKey.hex == Self.targetPubkey)
    }

    @Test func sessionIDMatchesVector() {
        let derived = PairingCrypto.sessionID(sessionSecret: data(Self.sessionSecret))
        #expect(derived.hexString == Self.sessionID)
    }

    @Test func ecdhSourceSideMatchesVector() throws {
        // The vector computes ECDH(source_priv, target_pub).
        let source = try PrivateKey(hex: Self.sourcePrivkey)
        let target = PublicKey(hex: Self.targetPubkey)!
        let shared = try PairingCrypto.ecdhShared(targetPrivateKey: source, sourcePublicKey: target)
        #expect(shared.hexString == Self.ecdhShared)
    }

    @Test func ecdhTargetSideMatchesVector() throws {
        // The target computes ECDH(target_priv, source_pub); it must equal the same
        // shared x-coordinate — the symmetry the SAS relies on.
        let target = try PrivateKey(hex: Self.targetPrivkey)
        let source = PublicKey(hex: Self.sourcePubkey)!
        let shared = try PairingCrypto.ecdhShared(targetPrivateKey: target, sourcePublicKey: source)
        #expect(shared.hexString == Self.ecdhShared)
    }

    @Test func sasInputMatchesVector() {
        let derived = PairingCrypto.sasInput(
            ecdhShared: data(Self.ecdhShared),
            sessionSecret: data(Self.sessionSecret)
        )
        #expect(derived.hexString == Self.sasInput)
    }

    @Test func sasCodeMatchesVector() {
        #expect(PairingCrypto.sasCode(sasInput: data(Self.sasInput)) == Self.sasCode)
    }

    @Test func sasCodeIsAlwaysSixDigits() {
        // A leading-zero SAS must still render six digits.
        var input = Data(count: 32)
        input[3] = 1 // be_u32 == 1 -> "000001"
        #expect(PairingCrypto.sasCode(sasInput: input) == "000001")
    }

    @Test func transcriptHashMatchesVector() {
        let derived = PairingCrypto.transcriptHash(
            sessionID: data(Self.sessionID),
            sourcePublicKey: data(Self.sourcePubkey),
            targetPublicKey: data(Self.targetPubkey),
            sasInput: data(Self.sasInput),
            sessionSecret: data(Self.sessionSecret)
        )
        #expect(derived.hexString == Self.transcriptHash)
    }

    @Test func constantTimeEqualsAgreesWithEquality() {
        let hash = data(Self.transcriptHash)
        let same = data(Self.transcriptHash)
        var flipped = hash
        flipped[0] ^= 0x01
        #expect(PairingCrypto.constantTimeEquals(hash, same))
        #expect(!PairingCrypto.constantTimeEquals(hash, flipped))
        #expect(!PairingCrypto.constantTimeEquals(hash, hash.dropLast()))
    }
}
