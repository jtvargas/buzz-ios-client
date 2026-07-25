import NostrCore

/// The key-custody operations sign-out needs, behind a seam so the
/// delete-verification boundary is testable with a double. ``KeychainSigner`` is
/// the production conformer.
protocol IdentityKeyCustody: Sendable {
    func delete() throws
    func loadPrivateKey() throws -> PrivateKey?
}

extension KeychainSigner: IdentityKeyCustody {}

/// The verdict of attempting to remove the identity key on sign-out.
enum SignOutResult: Equatable {
    /// The key was deleted and confirmed gone — safe to return to onboarding.
    case signedOut
    /// The key is still loadable after the delete attempt — the sign-out MUST NOT
    /// report success while the `nsec` remains recoverable on this device.
    case keyNotCleared
}

/// Deletes the identity key and verifies it is actually gone.
///
/// A security boundary: a sign-out reports success only when the key can no longer
/// be loaded, so a Keychain delete that throws — or silently leaves the item in
/// place — never masquerades as a completed sign-out. The delete is idempotent, so
/// running it when the key is already absent is harmless.
func deleteAndVerifyKey(_ custody: any IdentityKeyCustody) -> SignOutResult {
    try? custody.delete()
    return (try? custody.loadPrivateKey()) == nil ? .signedOut : .keyNotCleared
}
