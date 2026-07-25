import CryptoKit
import Foundation

/// The NIP-AB v1 key-derivation suite: session id, SAS, and transcript binding.
///
/// Every derivation is HKDF-SHA256 with a labelled `info` string for domain
/// separation, so no two outputs of the same `session_secret` are correlated. The
/// ECDH step reuses NostrCore's existing raw (unhashed) x-coordinate agreement —
/// the same primitive NIP-44 v2 is built on and validated against — which is
/// exactly what NIP-AB requires (many libraries hash the ECDH output by default;
/// this one does not).
///
/// Outputs are validated byte-for-byte against NIP-AB's published test vectors, so
/// a SAS this derives matches the desktop's, and a transcript hash this verifies is
/// the one the desktop committed to.
public enum PairingCrypto {
    /// `session_id = HKDF-SHA256(IKM=session_secret, salt="", info="nostr-pair-session-id", L=32)`.
    ///
    /// Proves the target holds the QR's secret without putting the secret on the
    /// wire: it is sent in the `offer` and the source re-derives and compares.
    public static func sessionID(sessionSecret: Data) -> Data {
        hkdf(ikm: sessionSecret, salt: Data(), info: "nostr-pair-session-id", length: 32)
    }

    /// The raw secp256k1 ECDH x-coordinate — **unhashed**, per NIP-AB.
    ///
    /// Symmetric: the source's `ECDH(source_priv, target_pub)` yields the identical
    /// value, which is what lets both sides derive the same SAS.
    public static func ecdhShared(targetPrivateKey: PrivateKey, sourcePublicKey: PublicKey) throws -> Data {
        try NIP44.sharedSecret(privateKey: targetPrivateKey, peer: sourcePublicKey)
    }

    /// `sas_input = HKDF-SHA256(IKM=ecdh_shared, salt=session_secret, info="nostr-pair-sas-v1", L=32)`.
    public static func sasInput(ecdhShared: Data, sessionSecret: Data) -> Data {
        hkdf(ikm: ecdhShared, salt: sessionSecret, info: "nostr-pair-sas-v1", length: 32)
    }

    /// The six-digit decimal SAS code, zero-padded: `be_u32(sas_input[0..4]) mod 1_000_000`.
    ///
    /// This is the value the user visually compares on both screens — the primary
    /// MITM defence. Always six digits (e.g. `"047291"`).
    public static func sasCode(sasInput: Data) -> String {
        var value: UInt32 = 0
        for byte in sasInput.prefix(4) {
            value = (value << 8) | UInt32(byte)
        }
        return String(format: "%06u", value % 1_000_000)
    }

    /// The transcript hash: `HKDF-SHA256` over
    /// `session_id ‖ source_pub ‖ target_pub ‖ sas_input`, salted with the session
    /// secret, `info="nostr-pair-transcript-v1"`, `L=32`.
    ///
    /// Binds the source's `sas-confirm` to the exact session parameters. The pubkeys
    /// are the 32-byte x-only coordinates, concatenated with no delimiter.
    public static func transcriptHash(
        sessionID: Data,
        sourcePublicKey: Data,
        targetPublicKey: Data,
        sasInput: Data,
        sessionSecret: Data
    ) -> Data {
        var transcript = Data(capacity: 128)
        transcript.append(sessionID)
        transcript.append(sourcePublicKey)
        transcript.append(targetPublicKey)
        transcript.append(sasInput)
        return hkdf(ikm: transcript, salt: sessionSecret, info: "nostr-pair-transcript-v1", length: 32)
    }

    /// A constant-time equality check for the transcript-hash comparison, so a near
    /// match cannot be distinguished from a far one by timing (NIP-AB requires it).
    ///
    /// The length branch leaks only length, and both operands here are fixed 32-byte
    /// hashes, so it leaks nothing an attacker does not already know.
    public static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    // MARK: - HKDF

    /// One-shot HKDF-SHA256 (extract then expand). An empty `salt` becomes the
    /// zero-length key CryptoKit's HMAC pads to the block size — identical to
    /// RFC 5869's "salt of HashLen zeros", which is what NIP-AB's `salt=""` means.
    private static func hkdf(ikm: Data, salt: Data, info: String, length: Int) -> Data {
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: salt,
            info: Data(info.utf8),
            outputByteCount: length
        )
        return derived.withUnsafeBytes { Data($0) }
    }
}
