import Foundation
@testable import NostrCore
import Testing

/// RFC 8439 conformance for the hand-rolled ChaCha20 keystream.
///
/// The published vectors pin the block function and the streaming XOR path
/// independently of NIP-44, so a regression in the cipher is caught here rather
/// than surfacing as an opaque MAC failure two layers up.
@Suite("ChaCha20 (RFC 8439)")
struct ChaCha20Tests {
    /// RFC 8439 §2.3.2: the canonical single-block keystream vector.
    @Test("block function matches the RFC 8439 §2.3.2 keystream")
    func blockFunctionVector() throws {
        let key = try #require(Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let nonce = try #require(Data(hexString: "000000090000004a00000000"))

        let block = ChaCha20.keystreamBlock(key: key, nonce: nonce, counter: 1)

        #expect(Data(block).hexString == "10f1e7e4d13b5915500fdd1fa32071c4"
            + "c7d1f4c733c068030422aa9ac3d46c4e"
            + "d2826446079faa0914c2d705d98b02a2"
            + "b5129cd1de164eb9cbd083e8a2503c4e")
    }

    /// RFC 8439 §2.4.2: encrypting a known plaintext with the counter starting at
    /// one. `process` starts at zero, so a 64-byte lead-in block is prepended and
    /// dropped to align the streams — which also exercises the multi-block path.
    @Test("encryption matches the RFC 8439 §2.4.2 vector")
    func encryptionVector() throws {
        let key = try #require(Data(hexString: "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"))
        let nonce = try #require(Data(hexString: "000000000000004a00000000"))
        let plaintext = Data("""
        Ladies and Gentlemen of the class of '99: If I could offer you \
        only one tip for the future, sunscreen would be it.
        """.utf8)

        var shifted = Data(count: 64)
        shifted.append(plaintext)
        let stream = ChaCha20.process(key: key, nonce: nonce, shifted)

        #expect(stream.dropFirst(64).hexString == "6e2e359a2568f98041ba0728dd0d6981"
            + "e97e7aec1d4360c20a27afccfd9fae0b"
            + "f91b65c5524733ab8f593dabcd62b357"
            + "1639d624e65152ab8f530c359f0861d8"
            + "07ca0dbf500d6a6156a38e088a22b65e"
            + "52bc514d16ccf806818ce91ab7793736"
            + "5af90bbf74a35be6b40b8eedf2785e42"
            + "874d")
    }

    @Test("is its own inverse across block boundaries")
    func roundTrips() {
        let key = Data(repeating: 0x2A, count: 32)
        let nonce = Data(repeating: 0x07, count: 12)

        for length in [1, 63, 64, 65, 128, 129, 1000] {
            let plaintext = Data((0 ..< length).map { UInt8($0 % 251) })
            let ciphertext = ChaCha20.process(key: key, nonce: nonce, plaintext)
            #expect(ciphertext != plaintext, "length \(length)")
            #expect(ChaCha20.process(key: key, nonce: nonce, ciphertext) == plaintext, "length \(length)")
        }
    }

    @Test("an empty input yields an empty output")
    func emptyInput() {
        let key = Data(repeating: 0, count: 32)
        let nonce = Data(repeating: 0, count: 12)
        #expect(ChaCha20.process(key: key, nonce: nonce, Data()).isEmpty)
    }
}
