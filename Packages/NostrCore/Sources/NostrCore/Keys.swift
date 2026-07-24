import Foundation
import P256K
import Security

/// A secp256k1 x-only public key: a 32-byte Nostr identity.
///
/// Nostr carries author identity in the 32-byte x-only form BIP-340 defines,
/// never the 33-byte compressed key, so that is the only representation modelled
/// here. The value is checked to be exactly 32 bytes on the way in; whether those
/// bytes name a point on the curve is left unchecked, because a public key only
/// has to parse when a signature is verified against it, and
/// `verifySchnorrSignature` already answers `false` for an off-curve key.
public struct PublicKey: Hashable, Sendable, Codable {
    /// The raw 32-byte x-only key.
    public let rawRepresentation: Data

    /// Wraps 32 raw bytes, rejecting any other length.
    public init?(rawRepresentation: Data) {
        guard rawRepresentation.count == 32 else { return nil }
        self.rawRepresentation = rawRepresentation
    }

    /// Parses a lowercase-hex x-only key.
    public init?(hex: String) {
        guard let bytes = Data(hexString: hex) else { return nil }
        self.init(rawRepresentation: bytes)
    }

    /// Parses a NIP-19 `npub1…` identifier.
    public init(npub: String) throws {
        let payload = try NIP19.decodePublicKey(npub)
        guard let key = PublicKey(rawRepresentation: payload) else {
            throw KeyError.invalidLength(payload.count)
        }
        self = key
    }

    /// Lowercase hex — the form written into event `pubkey` fields and filters.
    public var hex: String {
        rawRepresentation.hexString
    }

    /// NIP-19 `npub1…` — the form shown to people.
    public var npub: String {
        NIP19.encodePublicKey(rawRepresentation)
    }

    /// Coded as plain lowercase hex so an embedded key stays wire-shaped rather
    /// than nesting inside a keyed container.
    public init(from decoder: any Decoder) throws {
        let hex = try decoder.singleValueContainer().decode(String.self)
        guard let key = PublicKey(hex: hex) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "invalid public key: \(hex)")
            )
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }
}

/// A secp256k1 secret key: the private half of a Nostr identity.
///
/// Only the raw 32-byte scalar is stored. The libsecp256k1-backed key object is
/// rebuilt from those bytes for each operation rather than held onto, because it
/// wraps a non-`Sendable` C context and keeping one would bar this type from
/// crossing the actor boundaries a signer sits behind. Rebuilding costs far less
/// than the signing that follows it, so the trade is free in practice and buys a
/// plain `Sendable` value type.
///
/// The scalar is validated eagerly at initialisation, so an out-of-range key
/// fails where it is created rather than at the first attempt to sign. The type
/// is deliberately not `Equatable`, `Hashable`, or `Codable`, and its description
/// is redacted: the only ways the secret leaves the process are
/// `rawRepresentation` and `nsec`, each a call site worth auditing.
public struct PrivateKey: Sendable {
    /// The raw 32-byte secret scalar. Reading this is a secret-disclosure boundary.
    public let rawRepresentation: Data

    /// Generates a fresh identity from the system CSPRNG.
    public init() throws {
        guard let key = try? P256K.Schnorr.PrivateKey() else {
            throw KeyError.randomnessUnavailable
        }
        rawRepresentation = key.dataRepresentation
    }

    /// Creates a key from a raw 32-byte scalar, rejecting a wrong length or a
    /// scalar outside the valid range `[1, n)` for the curve.
    public init(rawRepresentation: Data) throws {
        guard rawRepresentation.count == 32 else {
            throw KeyError.invalidLength(rawRepresentation.count)
        }
        guard (try? P256K.Schnorr.PrivateKey(dataRepresentation: rawRepresentation)) != nil else {
            throw KeyError.invalidScalar
        }
        self.rawRepresentation = rawRepresentation
    }

    /// Creates a key from a lowercase-hex scalar.
    public init(hex: String) throws {
        guard let bytes = Data(hexString: hex) else { throw KeyError.invalidHex }
        try self.init(rawRepresentation: bytes)
    }

    /// Parses a NIP-19 `nsec1…` identifier.
    public init(nsec: String) throws {
        try self.init(rawRepresentation: NIP19.decodeSecretKey(nsec))
    }

    /// The x-only public key derived from this secret.
    public var publicKey: PublicKey {
        // `rawRepresentation` was validated at init, so both steps below are
        // total; a failure here could only be a libsecp256k1 defect.
        guard let backing = try? P256K.Schnorr.PrivateKey(dataRepresentation: rawRepresentation),
              let key = PublicKey(rawRepresentation: Data(backing.xonly.bytes))
        else {
            preconditionFailure("a validated secret scalar failed to derive a public key")
        }
        return key
    }

    /// NIP-19 `nsec1…`. Treat every call site as a secret-disclosure boundary.
    public var nsec: String {
        NIP19.encodeSecretKey(rawRepresentation)
    }

    /// Produces a BIP-340 signature over a 32-byte message digest.
    ///
    /// A Nostr signature covers the event id, which is already a SHA-256 digest,
    /// so the bytes are signed as-is with no further hashing. Fresh auxiliary
    /// randomness is drawn per signature, as BIP-340 recommends, to harden nonce
    /// derivation against fault-injection attacks. A visible consequence: two
    /// signatures over the same digest differ in their bytes yet both verify.
    public func signature(for digest: Data) throws -> Data {
        guard digest.count == 32 else { throw KeyError.invalidDigestLength(digest.count) }
        let backing = try P256K.Schnorr.PrivateKey(dataRepresentation: rawRepresentation)
        var message = Array(digest)
        var auxiliary = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, auxiliary.count, &auxiliary) == errSecSuccess else {
            throw KeyError.randomnessUnavailable
        }
        let signature = try auxiliary.withUnsafeMutableBytes { buffer in
            try backing.signature(message: &message, auxiliaryRand: buffer.baseAddress, strict: true)
        }
        return signature.dataRepresentation
    }
}

extension PrivateKey: CustomStringConvertible, CustomDebugStringConvertible {
    /// Redacted so a secret key cannot reach a log line through interpolation.
    public var description: String {
        "PrivateKey(redacted)"
    }

    public var debugDescription: String {
        description
    }
}

/// Errors from constructing a key or producing a signature.
public enum KeyError: Error, Equatable {
    /// A raw scalar or key was not the required 32 bytes; carries the length seen.
    case invalidLength(Int)
    /// A hex string was not well-formed lowercase hex.
    case invalidHex
    /// A 32-byte scalar fell outside the valid range `[1, n)` for secp256k1.
    case invalidScalar
    /// A value handed to signing was not the required 32-byte digest.
    case invalidDigestLength(Int)
    /// The system CSPRNG could not supply randomness for a key or a nonce.
    case randomnessUnavailable
}
