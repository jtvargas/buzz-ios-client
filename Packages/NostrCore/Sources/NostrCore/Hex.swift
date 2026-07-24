import Foundation

/// Lowercase hexadecimal coding for the byte strings Nostr carries on the wire.
///
/// Event ids, public keys, and signatures all travel as lowercase hex (NIP-01),
/// so encoding only ever emits lowercase and decoding is strict: input must be
/// an even number of characters drawn solely from `0-9a-f`. Uppercase and stray
/// characters are rejected rather than silently coerced, so a malformed
/// identifier fails immediately instead of hashing or verifying against the
/// wrong bytes.
public enum Hex {
    /// Renders a byte sequence as a lowercase hex string.
    public static func encode(_ bytes: some Sequence<UInt8>) -> String {
        var result = ""
        result.reserveCapacity(bytes.underestimatedCount * 2)
        for byte in bytes {
            result.append(lowercaseDigits[Int(byte >> 4)])
            result.append(lowercaseDigits[Int(byte & 0x0F)])
        }
        return result
    }

    /// Parses a lowercase hex string into its bytes, returning `nil` for any
    /// input that is not well-formed lowercase hex of even length.
    public static func decode(_ string: String) -> Data? {
        let ascii = string.utf8
        guard ascii.count % 2 == 0 else { return nil }

        var bytes = Data(capacity: ascii.count / 2)
        var highNibble: UInt8?
        for character in ascii {
            guard let nibble = nibbleValue(character) else { return nil }
            if let high = highNibble {
                bytes.append(high << 4 | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }
        return bytes
    }

    private static let lowercaseDigits = Array("0123456789abcdef")

    /// Maps a single ASCII byte to its 0-15 nibble value, accepting only
    /// lowercase hex digits.
    private static func nibbleValue(_ ascii: UInt8) -> UInt8? {
        switch ascii {
        case 0x30 ... 0x39: ascii &- 0x30 // 0-9
        case 0x61 ... 0x66: ascii &- 0x61 &+ 10 // a-f
        default: nil
        }
    }
}

public extension Data {
    /// The receiver rendered as lowercase hex.
    var hexString: String {
        Hex.encode(self)
    }

    /// Builds `Data` from a lowercase hex string, failing on malformed input.
    init?(hexString: String) {
        guard let decoded = Hex.decode(hexString) else { return nil }
        self = decoded
    }
}
