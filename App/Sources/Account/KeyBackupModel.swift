import NostrCore
import Observation

/// Drives the key-backup screen: it always shows the public `npub`, and reveals the
/// secret `nsec` only after a successful device authentication. On any auth failure
/// — or if the policy is unavailable, or the key cannot be loaded — the secret
/// stays hidden.
@MainActor
@Observable
final class KeyBackupModel {
    /// The identity's `npub`, always safe to display and copy.
    let npub: String

    /// The revealed `nsec`, non-nil only after a successful reveal. Cleared by
    /// ``hideSecret()`` and never persisted.
    private(set) var revealedNsec: String?
    private(set) var isAuthenticating = false
    /// Set when the most recent reveal attempt failed authentication or had no key.
    private(set) var revealFailed = false

    private let authenticator: any DeviceAuthenticating
    private let loadKey: () -> PrivateKey?

    init(selfPubkey: String, authenticator: any DeviceAuthenticating, loadKey: @escaping () -> PrivateKey?) {
        npub = PublicKey(hex: selfPubkey)?.npub ?? selfPubkey
        self.authenticator = authenticator
        self.loadKey = loadKey
    }

    var isRevealed: Bool { revealedNsec != nil }

    /// Authenticates and, only on success, loads and reveals the secret key.
    func revealSecret() async {
        guard revealedNsec == nil else { return }
        isAuthenticating = true
        revealFailed = false
        let authenticated = await authenticator.authenticate(reason: "Reveal your Hive secret key")
        isAuthenticating = false
        guard authenticated, let key = loadKey() else {
            revealFailed = true
            return
        }
        revealedNsec = key.nsec
    }

    /// Hides a revealed secret again.
    func hideSecret() {
        revealedNsec = nil
    }
}
