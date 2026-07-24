import Foundation
@testable import NostrCore
import Testing

@Suite("Hex coding")
struct HexTests {
    @Test("Encodes bytes as lowercase hex")
    func encodesLowercase() {
        let bytes = Data([0x00, 0x0F, 0xA0, 0xFF, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(Hex.encode(bytes) == "000fa0ffdeadbeef")
    }

    @Test("Round-trips arbitrary bytes")
    func roundTrips() {
        let bytes = Data((0 ..< 256).map { UInt8($0) })
        let encoded = Hex.encode(bytes)
        #expect(Hex.decode(encoded) == bytes)
    }

    @Test("Decodes a 32-byte pubkey-shaped string")
    func decodesPubkey() {
        let hex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
        let decoded = Hex.decode(hex)
        #expect(decoded?.count == 32)
        #expect(decoded?.hexString == hex)
    }

    @Test("Empty input decodes to empty data")
    func emptyInput() {
        #expect(Hex.decode("") == Data())
        #expect(Hex.encode(Data()) == "")
    }

    @Test("Rejects odd-length input")
    func rejectsOddLength() {
        #expect(Hex.decode("abc") == nil)
        #expect(Hex.decode("f") == nil)
    }

    @Test("Rejects uppercase input (strict lowercase)")
    func rejectsUppercase() {
        #expect(Hex.decode("ABCD") == nil)
        #expect(Hex.decode("00FF") == nil)
    }

    @Test("Rejects non-hex characters")
    func rejectsNonHex() {
        #expect(Hex.decode("00gg") == nil)
        #expect(Hex.decode("zz") == nil)
        #expect(Hex.decode("12 4") == nil)
    }

    @Test("Data convenience mirrors the enum")
    func dataConvenience() {
        let bytes = Data([0xCA, 0xFE])
        #expect(bytes.hexString == "cafe")
        #expect(Data(hexString: "cafe") == bytes)
        #expect(Data(hexString: "nope") == nil)
    }
}
