import Foundation

/// The observable phase of a target-side pairing session, as a UI needs it.
///
/// A small, closed set: the view model maps each to a screen (connecting spinner,
/// SAS comparison, transfer progress, success, error). The SAS code is carried in
/// ``comparing(sasCode:)`` so the screen has exactly the value to display.
public enum TargetPairingPhase: Sendable, Equatable {
    /// Not started.
    case idle
    /// Connecting to the pairing relay and publishing the offer.
    case connecting
    /// Both ephemeral keys are known; the user must compare this six-digit code
    /// against the one on the desktop and confirm or cancel.
    case comparing(sasCode: String)
    /// Dual consent is met; the credential is being decrypted and imported.
    case transferring
    /// The identity was imported into secure storage — success.
    case completed
    /// The user cancelled (or denied the SAS). Not an error to surface.
    case cancelled
    /// The session ended in a failure worth showing the user.
    case failed(NostrPairError)

    /// Whether the session has reached a terminal state.
    public var isTerminal: Bool {
        switch self {
        case .completed, .cancelled, .failed: true
        case .idle, .connecting, .comparing, .transferring: false
        }
    }
}

/// The application-specific sink for a validated, decrypted NIP-AB `payload`.
///
/// NIP-AB is a generic transport; what a `custom` payload *means* — Buzz's
/// `{relayUrl, pubkey, nsec}` credential — is the app's concern. The session hands
/// the decrypted payload here only after **both** transcript verification and the
/// user's SAS confirmation have passed, and sends `complete(true)` to the desktop
/// only if this returns `true`.
///
/// The implementer MUST enforce the app's payload contract (here: `payloadType ==
/// "custom"`, the nsec→pubkey equality check, and a valid relay URL) and MUST
/// return `true` only once the key is durably committed to secure storage.
public protocol PairingPayloadHandler: Sendable {
    /// Durably imports the decrypted payload. Returns `true` on durable success,
    /// `false` on any validation or storage failure (which the session reports to
    /// the desktop as `complete(success: false)`).
    func importPayload(payloadType: String, payload: String) async -> Bool
}
