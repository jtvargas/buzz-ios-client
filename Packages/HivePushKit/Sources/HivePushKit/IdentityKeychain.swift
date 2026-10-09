import NostrCore

/// The one way the app and its extensions open an identity key.
///
/// Keys are generic-password items under ``NostrCore/KeychainSigner/defaultService``,
/// one per community (its `keychainAccount`). Nothing here names a Keychain access
/// group, and that is deliberate: an item saved or read without
/// `kSecAttrAccessGroup` lands in the *first* group of the caller's
/// `keychain-access-groups` entitlement, and both the app and the extension list
/// the app's own application-identifier group first (`project.yml`, from
/// `HIVE_KEYCHAIN_ACCESS_GROUP` in `Config/Shared.xcconfig`). So the same query
/// resolves to the same items from either process — and from an unsigned CI build,
/// where no entitlement exists and the default is the app's own group anyway.
/// Passing the group explicitly would buy nothing on a device and break every
/// Keychain call under CI, where the build has no entitlement to match it.
///
/// Keep that ordering invariant when adding groups: a new group must go *after*
/// the identity group in both entitlements, or every stored key silently moves.
public enum IdentityKeychain {
    /// A signer over the key stored for `account`. The key is read fresh on every
    /// operation, so a signer for an account with no key is cheap to make and
    /// fails only when asked to sign.
    public static func signer(account: String) -> KeychainSigner {
        KeychainSigner(account: account)
    }

    /// Whether a usable key is stored under `account`.
    ///
    /// A Keychain that cannot be read at all — CI has no usable one — answers no,
    /// which lands a caller on its identity gate rather than on a crash.
    public static func hasStoredKey(account: String) -> Bool {
        (try? signer(account: account).loadPrivateKey()) != nil
    }
}
