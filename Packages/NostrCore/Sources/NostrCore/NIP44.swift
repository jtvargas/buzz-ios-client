import CryptoKit
import Foundation
import P256K
import Security

/// NIP-44 v2 authenticated encryption.
///
/// The scheme derives a long-lived *conversation key* from an ECDH agreement —
/// the raw x-coordinate of the shared point, fed unhashed into HKDF-extract
/// salted with `"nip44-v2"`. Per message it then expands a fresh 32-byte nonce
/// into a ChaCha20 key, a ChaCha20 nonce, and an HMAC key. The plaintext is
/// length-prefixed and zero-padded up to a power-of-two bucket so its size leaks
/// only coarsely, encrypted with raw ChaCha20, and authenticated with an
/// HMAC-SHA256 over the nonce and ciphertext together. The wire payload is
/// `base64(0x02 ‖ nonce ‖ ciphertext ‖ mac)`.
///
/// Every derivation and transformation here is checked against the official
/// NIP-44 vector suite (paulmillr/nip44): a payload this produces must decrypt
/// in every other conforming client, and every conforming client's payload must
/// decrypt here.
public enum NIP44 {
    /// The reasons encryption or decryption can fail.
    public enum Failure: Error, Equatable {
        /// A plaintext of zero bytes was offered; NIP-44 defines no empty message.
        case emptyPlaintext
        /// A plaintext exceeded the 65 535-byte ceiling; carries the length seen.
        case plaintextTooLong(Int)
        /// The payload was not decodable base64, or its length fell outside bounds.
        case malformedPayload
        /// The payload named an encryption version this client cannot read. A
        /// deliberate signal, distinct from ``malformedPayload``: it tells a
        /// caller to upgrade rather than to discard the message as corrupt.
        case unsupportedVersion(UInt8)
        /// The HMAC did not match — the payload was forged or corrupted, or it was
        /// opened with the wrong conversation key.
        case authenticationFailed
        /// The decrypted length prefix and padding did not describe a valid frame.
        case invalidPadding
        /// The peer key did not name a point usable for key agreement.
        case keyAgreementFailed
        /// The system CSPRNG could not supply a nonce.
        case randomnessUnavailable
    }

    /// The payload version byte this implementation reads and writes.
    static let version: UInt8 = 0x02

    /// The inclusive plaintext-length bounds NIP-44 permits, in bytes.
    static let minPlaintextBytes = 1
    static let maxPlaintextBytes = 65535

    /// The decoded-payload length bounds, in bytes.
    ///
    /// A payload is `version(1) ‖ nonce(32) ‖ ciphertext ‖ mac(32)`. The
    /// ciphertext is the padded frame: at least `2 + 32` bytes for a one-byte
    /// message, at most `2 + paddedLength(65535)` for the longest.
    static let minPayloadBytes = 1 + 32 + (2 + 32) + 32 // 99
    static let maxPayloadBytes = 1 + 32 + (2 + 65536) + 32 // 65603

    /// The three keys expanded from the conversation key for a single message.
    struct MessageKeys {
        let chachaKey: Data
        let chachaNonce: Data
        let hmacKey: Data
    }

    // MARK: - Key derivation

    /// The long-lived key both directions of a conversation share.
    ///
    /// Symmetric by construction — `conversationKey(a, B) == conversationKey(b, A)`
    /// — because the ECDH x-coordinate is the same shared point computed from
    /// either side.
    public static func conversationKey(privateKey: PrivateKey, peer: PublicKey) throws -> Data {
        let shared = try sharedSecret(privateKey: privateKey, peer: peer)
        let pseudoRandomKey = HKDF<CryptoKit.SHA256>.extract(
            inputKeyMaterial: SymmetricKey(data: shared),
            salt: Data("nip44-v2".utf8)
        )
        return pseudoRandomKey.withUnsafeBytes { Data($0) }
    }

    /// Per-message keys, derived by expanding the conversation key against a nonce.
    ///
    /// HKDF-expand yields 76 bytes, split into the 32-byte ChaCha20 key, the
    /// 12-byte ChaCha20 nonce, and the 32-byte HMAC key — in that order.
    static func messageKeys(conversationKey: Data, nonce: Data) -> MessageKeys {
        let expanded = HKDF<CryptoKit.SHA256>.expand(
            pseudoRandomKey: SymmetricKey(data: conversationKey),
            info: nonce,
            outputByteCount: 76
        )
        let material = expanded.withUnsafeBytes { [UInt8]($0) }
        return MessageKeys(
            chachaKey: Data(material[0 ..< 32]),
            chachaNonce: Data(material[32 ..< 44]),
            hmacKey: Data(material[44 ..< 76])
        )
    }

    /// The ECDH shared secret: the raw x-coordinate of the shared point.
    ///
    /// Left unhashed on purpose. The default secp256k1 ECDH hashes the point with
    /// SHA-256, but NIP-44 feeds the bare coordinate into HKDF, so the default
    /// would silently agree a different secret than every other client. The
    /// peer's key is x-only, so it is lifted assuming even Y — the BIP-340
    /// convention both ends already use for identity keys.
    static func sharedSecret(privateKey: PrivateKey, peer: PublicKey) throws -> Data {
        var compressed = Data([0x02])
        compressed.append(peer.rawRepresentation)

        guard let peerKey = try? P256K.KeyAgreement.PublicKey(
            dataRepresentation: compressed,
            format: .compressed
        ) else { throw Failure.keyAgreementFailed }

        guard let key = try? P256K.KeyAgreement.PrivateKey(dataRepresentation: privateKey.rawRepresentation) else {
            throw Failure.keyAgreementFailed
        }

        // `.compressed` serialises the shared point as a parity prefix followed by
        // X and, critically, skips the library's default SHA-256 hashing — so the
        // bytes here are the raw point. NIP-44 wants only the X coordinate.
        let point = key.sharedSecretFromKeyAgreement(with: peerKey, format: .compressed)
        let bytes = point.withUnsafeBytes { Data($0) }
        guard bytes.count == 33 else { throw Failure.keyAgreementFailed }
        return bytes.dropFirst()
    }

    // MARK: - Padding

    /// The padded plaintext length for `unpadded`, per NIP-44's power-of-two
    /// scheme: buckets coarsen as messages grow, so the ciphertext length leaks
    /// far less than it would byte for byte.
    static func paddedLength(_ unpadded: Int) -> Int {
        guard unpadded > 32 else { return 32 }
        // The next power of two at or above `unpadded`, found from the bit width
        // of the largest set bit in `unpadded - 1`.
        let nextPowerOfTwo = 1 << (Int.bitWidth - (unpadded - 1).leadingZeroBitCount)
        let chunk = nextPowerOfTwo <= 256 ? 32 : nextPowerOfTwo / 8
        return chunk * ((unpadded - 1) / chunk + 1)
    }

    /// Frames a plaintext as `length(2, big-endian) ‖ plaintext ‖ zero-padding`.
    static func pad(_ plaintext: Data) throws -> Data {
        guard plaintext.count >= minPlaintextBytes else { throw Failure.emptyPlaintext }
        guard plaintext.count <= maxPlaintextBytes else { throw Failure.plaintextTooLong(plaintext.count) }

        let target = paddedLength(plaintext.count)
        var frame = Data(capacity: 2 + target)
        frame.append(UInt8(truncatingIfNeeded: plaintext.count >> 8))
        frame.append(UInt8(truncatingIfNeeded: plaintext.count))
        frame.append(plaintext)
        frame.append(Data(count: target - plaintext.count))
        return frame
    }

    /// Recovers the plaintext from a padded frame, rejecting any frame whose
    /// declared length or overall size is inconsistent with the padding scheme.
    static func unpad(_ padded: Data) throws -> Data {
        guard padded.count >= 2 else { throw Failure.invalidPadding }
        let bytes = [UInt8](padded)
        let declared = Int(bytes[0]) << 8 | Int(bytes[1])

        guard declared >= minPlaintextBytes,
              declared <= maxPlaintextBytes,
              bytes.count == 2 + paddedLength(declared)
        else { throw Failure.invalidPadding }

        return Data(bytes[2 ..< (2 + declared)])
    }

    // MARK: - Encrypt / decrypt

    /// Encrypts `plaintext` under `conversationKey` with a fresh random nonce.
    ///
    /// The nonce is drawn once from the system CSPRNG via `SecRandomCopyBytes`,
    /// matching the key-generation path elsewhere in this package; a single
    /// audited call is preferable to sampling a generator byte by byte.
    public static func encrypt(_ plaintext: String, conversationKey: Data) throws -> String {
        var nonce = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce) == errSecSuccess else {
            throw Failure.randomnessUnavailable
        }
        return try encrypt(plaintext, conversationKey: conversationKey, nonce: Data(nonce))
    }

    /// Encrypts with a caller-supplied nonce.
    ///
    /// Reusing a nonce with a given conversation key is catastrophic for a stream
    /// cipher, so this overload stays internal: it exists so the official vectors
    /// can be reproduced byte for byte, while the public API above always draws a
    /// fresh nonce.
    static func encrypt(_ plaintext: String, conversationKey: Data, nonce: Data) throws -> String {
        let padded = try pad(Data(plaintext.utf8))
        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)
        let ciphertext = ChaCha20.process(key: keys.chachaKey, nonce: keys.chachaNonce, padded)

        // The MAC covers the nonce and the ciphertext together, so neither can be
        // substituted against the other.
        var authenticated = nonce
        authenticated.append(ciphertext)
        let mac = HMAC<CryptoKit.SHA256>.authenticationCode(
            for: authenticated,
            using: SymmetricKey(data: keys.hmacKey)
        )

        var payload = Data([version])
        payload.append(nonce)
        payload.append(ciphertext)
        payload.append(Data(mac))
        return payload.base64EncodedString()
    }

    /// Decrypts a base64 NIP-44 payload under `conversationKey`.
    ///
    /// The MAC is verified before any attempt to decrypt, using CryptoKit's
    /// constant-time comparison so repeated attempts cannot leak the expected tag.
    public static func decrypt(_ payload: String, conversationKey: Data) throws -> String {
        // A leading '#' is NIP-44's reserved marker for a future, unreadable
        // encoding. It is surfaced as an unsupported version rather than as
        // garbage so a caller can tell "needs upgrade" from "corrupt", and it is
        // checked before base64 decoding because such a payload is not valid
        // base64 to begin with.
        guard !payload.hasPrefix("#") else { throw Failure.unsupportedVersion(0) }

        guard let decoded = Data(base64Encoded: payload) else { throw Failure.malformedPayload }
        let bytes = [UInt8](decoded)
        guard bytes.count >= minPayloadBytes, bytes.count <= maxPayloadBytes else {
            throw Failure.malformedPayload
        }
        guard bytes[0] == version else { throw Failure.unsupportedVersion(bytes[0]) }

        let nonce = Data(bytes[1 ..< 33])
        let ciphertext = Data(bytes[33 ..< (bytes.count - 32)])
        let mac = Data(bytes[(bytes.count - 32)...])

        let keys = messageKeys(conversationKey: conversationKey, nonce: nonce)

        var authenticated = nonce
        authenticated.append(ciphertext)
        guard HMAC<CryptoKit.SHA256>.isValidAuthenticationCode(
            mac,
            authenticating: authenticated,
            using: SymmetricKey(data: keys.hmacKey)
        ) else { throw Failure.authenticationFailed }

        let padded = ChaCha20.process(key: keys.chachaKey, nonce: keys.chachaNonce, ciphertext)
        let plaintext = try unpad(padded)

        // Reachable only for a payload that authenticated yet carries non-UTF-8
        // content — a well-formed frame from a peer that ignored the text rule.
        guard let text = String(data: plaintext, encoding: .utf8) else { throw Failure.invalidPadding }
        return text
    }
}
