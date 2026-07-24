import Foundation
@testable import NostrCore
import Testing

@Suite("Bech32 and NIP-19 bare entities")
struct Bech32Tests {
    // Reference vectors derived from a standalone BIP-173 implementation.
    // npub is fiatjaf's public identifier, confirming external interop.
    private let pubkeyHex = "3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d"
    private let npub = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3evf6u64th6gkwsyjh6w6"

    private let secretHex = "0000000000000000000000000000000000000000000000000000000000000001"
    private let nsec = "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqsmhltgl"

    private let noteHex = "1f93528869969956628ebbd2ec68cd56e7003bcf6723e648d405b3d95d7ccf33"
    private let note = "note1r7f49zrfj6v4vc5wh0fwc6xd2mnsqw70vu37vjx5qkeajhtueues2t6tdk"

    @Test("Encodes npub to the reference value")
    func encodesNpub() throws {
        let raw = try #require(Data(hexString: pubkeyHex))
        #expect(NIP19.encodePublicKey(raw) == npub)
    }

    @Test("Decodes npub back to the raw key")
    func decodesNpub() throws {
        let decoded = try NIP19.decodePublicKey(npub)
        #expect(decoded.hexString == pubkeyHex)
    }

    @Test("Round-trips nsec")
    func roundTripsNsec() throws {
        let raw = try #require(Data(hexString: secretHex))
        #expect(NIP19.encodeSecretKey(raw) == nsec)
        #expect(try NIP19.decodeSecretKey(nsec).hexString == secretHex)
    }

    @Test("Round-trips note")
    func roundTripsNote() throws {
        let raw = try #require(Data(hexString: noteHex))
        #expect(NIP19.encodeEventID(raw) == note)
        #expect(try NIP19.decodeEventID(note).hexString == noteHex)
    }

    @Test("Generic encode/decode round-trips a payload")
    func genericRoundTrip() throws {
        let payload = Data((0 ..< 32).map { UInt8($0) })
        let encoded = Bech32.encode(humanReadablePart: "npub", payload: payload)
        let decoded = try Bech32.decode(encoded)
        #expect(decoded.humanReadablePart == "npub")
        #expect(decoded.payload == payload)
    }

    @Test("Rejects a mutated checksum")
    func rejectsBadChecksum() {
        var mutated = Array(npub)
        mutated[mutated.count - 1] = mutated.last == "6" ? "7" : "6"
        #expect(throws: Bech32.DecodingError.checksumInvalid) {
            _ = try Bech32.decode(String(mutated))
        }
    }

    @Test("Rejects mixed-case input")
    func rejectsMixedCase() {
        let mixed = "npub180cvv07tjdrrgpa0j7j7tmnyl2yr6yr7l8j4s3EVF6u64th6gkwsyjh6w6"
        #expect(throws: Bech32.DecodingError.mixedCase) {
            _ = try Bech32.decode(mixed)
        }
    }

    @Test("Rejects a string with no separator")
    func rejectsMissingSeparator() {
        #expect(throws: Bech32.DecodingError.separatorMissing) {
            _ = try Bech32.decode("npubxyz")
        }
    }

    @Test("Rejects a character outside the alphabet")
    func rejectsBadCharacter() {
        // 'b', 'i', 'o', '1' are excluded from the bech32 alphabet.
        #expect(throws: (any Error).self) {
            _ = try Bech32.decode("npub1bio")
        }
    }

    @Test("Decoding as the wrong prefix fails")
    func rejectsWrongPrefix() {
        #expect(throws: NIP19.EntityError.self) {
            _ = try NIP19.decodeSecretKey(npub)
        }
    }

    @Test("Decoding a non-32-byte payload fails")
    func rejectsWrongLength() {
        // A 2-byte payload encoded under the npub prefix is well-formed bech32
        // but not a valid bare public key.
        let shortEntity = Bech32.encode(humanReadablePart: "npub", payload: Data([0x01, 0x02]))
        #expect(throws: NIP19.EntityError.self) {
            _ = try NIP19.decodePublicKey(shortEntity)
        }
    }
}
