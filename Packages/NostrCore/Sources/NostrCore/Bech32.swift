import Foundation

/// Bech32 (BIP-173) string coding, in the classic checksum variant NIP-19 uses
/// for its bare identifiers.
///
/// NIP-19 keeps the original bech32 checksum constant (`1`) rather than the
/// bech32m constant, so this is deliberately not bech32m. Only the generic
/// five-bit machinery lives here; the `npub` / `nsec` / `note` entities are
/// layered on top in `NIP19`. The richer TLV entities (`nprofile`, `nevent`,
/// `naddr`) are intentionally out of scope.
public enum Bech32 {
    public enum DecodingError: Error, Equatable {
        case mixedCase
        case separatorMissing
        case humanReadablePartEmpty
        case dataTooShort
        case characterOutsideCharset
        case checksumInvalid
        case paddingInvalid
    }

    /// The bech32 five-bit alphabet, indexed by symbol value.
    private static let alphabet = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")

    /// Reverse map from an ASCII byte to its five-bit value, or `sentinel` when
    /// the byte is not part of the alphabet.
    private static let sentinel: UInt8 = 0xFF
    private static let reverseAlphabet: [UInt8] = {
        var table = [UInt8](repeating: sentinel, count: 128)
        for (symbolValue, character) in alphabet.enumerated() {
            if let ascii = character.asciiValue {
                table[Int(ascii)] = UInt8(symbolValue)
            }
        }
        return table
    }()

    private static let checksumSymbolCount = 6

    // MARK: - Encoding

    /// Encodes a byte payload under a human-readable prefix, appending the
    /// six-symbol checksum.
    public static func encode(humanReadablePart prefix: String, payload: Data) -> String {
        let fiveBit = regroup(Array(payload), fromBitWidth: 8, toBitWidth: 5, padding: true) ?? []
        let checksumSymbols = checksum(humanReadablePart: prefix, fiveBitData: fiveBit)
        let symbols = (fiveBit + checksumSymbols).map { alphabet[Int($0)] }
        return prefix + "1" + String(symbols)
    }

    // MARK: - Decoding

    /// Decodes a bech32 string into its prefix and byte payload, validating the
    /// checksum and rejecting mixed-case input as BIP-173 requires.
    public static func decode(_ string: String) throws -> (humanReadablePart: String, payload: Data) {
        let lowercased = string.lowercased()
        let uppercased = string.uppercased()
        guard string == lowercased || string == uppercased else { throw DecodingError.mixedCase }

        guard let separatorIndex = lowercased.lastIndex(of: "1") else {
            throw DecodingError.separatorMissing
        }

        let prefix = String(lowercased[lowercased.startIndex ..< separatorIndex])
        let dataSection = lowercased[lowercased.index(after: separatorIndex)...]
        guard !prefix.isEmpty else { throw DecodingError.humanReadablePartEmpty }
        guard dataSection.count >= checksumSymbolCount else { throw DecodingError.dataTooShort }

        var fiveBit = [UInt8]()
        fiveBit.reserveCapacity(dataSection.count)
        for scalar in dataSection.unicodeScalars {
            guard scalar.value < 128 else { throw DecodingError.characterOutsideCharset }
            let symbolValue = reverseAlphabet[Int(scalar.value)]
            guard symbolValue != sentinel else { throw DecodingError.characterOutsideCharset }
            fiveBit.append(symbolValue)
        }

        guard verifyChecksum(humanReadablePart: prefix, fiveBitData: fiveBit) else {
            throw DecodingError.checksumInvalid
        }

        let payloadSymbols = Array(fiveBit.dropLast(checksumSymbolCount))
        guard let bytes = regroup(payloadSymbols, fromBitWidth: 5, toBitWidth: 8, padding: false) else {
            throw DecodingError.paddingInvalid
        }
        return (prefix, Data(bytes))
    }

    // MARK: - Checksum (BIP-173 polymod)

    private static func polymod(_ values: [UInt8]) -> UInt32 {
        let generators: [UInt32] = [0x3B6A_57B2, 0x2650_8E6D, 0x1EA1_19FA, 0x3D42_33DD, 0x2A14_62B3]
        var accumulator: UInt32 = 1
        for value in values {
            let carry = accumulator >> 25
            accumulator = ((accumulator & 0x01FF_FFFF) << 5) ^ UInt32(value)
            for position in 0 ..< 5 where (carry >> UInt32(position)) & 1 == 1 {
                accumulator ^= generators[position]
            }
        }
        return accumulator
    }

    private static func expand(humanReadablePart prefix: String) -> [UInt8] {
        let bytes = Array(prefix.utf8)
        return bytes.map { $0 >> 5 } + [0] + bytes.map { $0 & 0x1F }
    }

    private static func checksum(humanReadablePart prefix: String, fiveBitData: [UInt8]) -> [UInt8] {
        let values = expand(humanReadablePart: prefix) + fiveBitData + [0, 0, 0, 0, 0, 0]
        let mod = polymod(values) ^ 1
        return (0 ..< 6).map { index in
            UInt8((mod >> (5 * (5 - UInt32(index)))) & 0x1F)
        }
    }

    private static func verifyChecksum(humanReadablePart prefix: String, fiveBitData: [UInt8]) -> Bool {
        polymod(expand(humanReadablePart: prefix) + fiveBitData) == 1
    }

    // MARK: - Bit regrouping

    /// Regroups a byte stream from one bit width to another, as bech32 needs to
    /// move between eight-bit bytes and its five-bit alphabet. Returns `nil`
    /// when unpacking leaves non-zero padding or too many leftover bits.
    private static func regroup(
        _ input: [UInt8],
        fromBitWidth: UInt32,
        toBitWidth: UInt32,
        padding: Bool
    ) -> [UInt8]? {
        var accumulator: UInt32 = 0
        var bitsHeld: UInt32 = 0
        let mask: UInt32 = (1 << toBitWidth) - 1
        var output = [UInt8]()

        for value in input {
            accumulator = (accumulator << fromBitWidth) | UInt32(value)
            bitsHeld += fromBitWidth
            while bitsHeld >= toBitWidth {
                bitsHeld -= toBitWidth
                output.append(UInt8((accumulator >> bitsHeld) & mask))
            }
        }

        if padding {
            if bitsHeld > 0 {
                output.append(UInt8((accumulator << (toBitWidth - bitsHeld)) & mask))
            }
        } else if bitsHeld >= fromBitWidth || (accumulator << (toBitWidth - bitsHeld)) & mask != 0 {
            return nil
        }

        return output
    }
}

/// NIP-19 bare bech32 entities: `npub`, `nsec`, and `note`.
///
/// Each wraps a single 32-byte value — a public key, a secret key, or an event
/// id — under a fixed prefix. The TLV entities (`nprofile`, `nevent`, `naddr`)
/// are not modelled here.
public enum NIP19 {
    public enum EntityError: Error, Equatable {
        case unexpectedPrefix(expected: String, found: String)
        case unexpectedPayloadLength(Int)
    }

    /// The 32-byte payload length shared by every bare entity.
    private static let payloadLength = 32

    public static func encodePublicKey(_ rawKey: Data) -> String {
        Bech32.encode(humanReadablePart: "npub", payload: rawKey)
    }

    public static func decodePublicKey(_ npub: String) throws -> Data {
        try decodeBare(npub, expecting: "npub")
    }

    public static func encodeSecretKey(_ rawKey: Data) -> String {
        Bech32.encode(humanReadablePart: "nsec", payload: rawKey)
    }

    public static func decodeSecretKey(_ nsec: String) throws -> Data {
        try decodeBare(nsec, expecting: "nsec")
    }

    public static func encodeEventID(_ rawID: Data) -> String {
        Bech32.encode(humanReadablePart: "note", payload: rawID)
    }

    public static func decodeEventID(_ note: String) throws -> Data {
        try decodeBare(note, expecting: "note")
    }

    /// Decodes a bare entity, asserting both the expected prefix and the fixed
    /// 32-byte payload length.
    private static func decodeBare(_ string: String, expecting prefix: String) throws -> Data {
        let (foundPrefix, payload) = try Bech32.decode(string)
        guard foundPrefix == prefix else {
            throw EntityError.unexpectedPrefix(expected: prefix, found: foundPrefix)
        }
        guard payload.count == payloadLength else {
            throw EntityError.unexpectedPayloadLength(payload.count)
        }
        return payload
    }
}
