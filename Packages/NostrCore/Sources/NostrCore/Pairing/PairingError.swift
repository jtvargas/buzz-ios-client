import Foundation

/// Everything that can go wrong parsing a pairing QR or running a pairing session,
/// as a single typed surface a UI can map to human copy.
public enum NostrPairError: Error, Equatable, Sendable {
    // MARK: QR parse (NIP-AB §QR Code Format)

    /// The URI exceeded ``NostrPairURI/maxURILength`` — a scanning DoS guard.
    case uriTooLong(Int)
    /// The string was not a `scheme://body` URI at all.
    case malformedURI
    /// The scheme was present but not `nostrpair`.
    case unexpectedScheme(String)
    /// The authority was not exactly 64 lowercase-hex characters naming a valid
    /// x-only public key.
    case invalidSourcePublicKey
    /// No `secret` query parameter was present.
    case missingSessionSecret
    /// The `secret` was not exactly 64 lowercase-hex characters (32 bytes).
    case invalidSessionSecret
    /// The `secret` decoded to all zeros, which NIP-AB forbids.
    case zeroSessionSecret
    /// No usable `ws`/`wss` relay was listed.
    case missingRelay
    /// The `v` parameter named a version this build does not implement; the UI
    /// should prompt the user to update. Carries the raw value seen.
    case unsupportedVersion(String)

    // MARK: Session (NIP-AB protocol)

    /// The relay could not be reached, or the socket dropped mid-session.
    case connectionFailed(String)
    /// The relay rejected the ephemeral identity's NIP-42 authentication.
    case authenticationRejected(String)
    /// The `transcript_hash` in `sas-confirm` did not match the local derivation —
    /// session inconsistency or tampering (NIP-AB abort `sas_mismatch`).
    case transcriptMismatch
    /// A protocol step or the whole session exceeded its deadline.
    case timedOut
    /// The peer sent an `abort`, carrying its reason string.
    case peerAborted(String)
    /// The decrypted payload was not the shape this application accepts (wrong
    /// `payload_type`, oversized, or a credential that failed validation).
    case invalidPayload(String)
    /// The decrypted key material could not be committed to secure storage, so the
    /// pairing is reported to the source as `complete(success: false)`.
    case importFailed(String)
    /// An unrecoverable local condition (NIP-AB abort `protocol_error`).
    case internalError(String)
}

/// The NIP-AB `abort` reason strings, as a closed set.
///
/// Kept distinct from ``NostrPairError`` because these are the exact tokens that go
/// on the wire in an `abort` message; the spec defines their meanings and a peer
/// keys its own handling off them.
public enum PairingAbortReason: String, Sendable, Equatable {
    /// SAS codes did not match, or transcript-hash verification failed.
    case sasMismatch = "sas_mismatch"
    /// The user explicitly denied the pairing.
    case userDenied = "user_denied"
    /// The session timed out.
    case timeout
    /// A local fatal condition. Never sent in response to a peer's out-of-order or
    /// validation-failing event (those are silently discarded).
    case protocolError = "protocol_error"
}
