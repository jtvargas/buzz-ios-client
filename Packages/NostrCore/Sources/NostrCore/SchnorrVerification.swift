import Foundation
import P256K

/// Verifies a BIP-340 Schnorr signature over a 32-byte message.
///
/// A free function because verification needs no secret material — only the
/// signature, the message that was signed, and the signer's 32-byte x-only
/// public key. Nostr signs an event id, which is already a SHA-256 digest, so
/// the message bytes are verified as-is with no further hashing.
///
/// Any malformed input — a signature that is not 64 bytes, a message that is not
/// 32 bytes, or a key that is not a 32-byte value parsing to a valid curve point
/// — makes verification return `false` rather than throw, so a caller gets a
/// single boolean answer to "does this signature hold".
///
/// This is the only signing-adjacent surface in this layer: it deliberately
/// introduces no key or signing types. Those arrive with the keys module.
public func verifySchnorrSignature(
    signature: Data,
    message: Data,
    publicKeyXOnly: Data
) -> Bool {
    guard signature.count == 64, message.count == 32, publicKeyXOnly.count == 32 else {
        return false
    }
    guard let parsedSignature = try? P256K.Schnorr.SchnorrSignature(dataRepresentation: signature) else {
        return false
    }
    let xOnlyKey = P256K.Schnorr.XonlyKey(dataRepresentation: publicKeyXOnly)
    var messageBytes = Array(message)
    return xOnlyKey.isValid(parsedSignature, for: &messageBytes)
}
