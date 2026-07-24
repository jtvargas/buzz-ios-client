import Foundation
import Security

/// The narrow slice of Keychain behaviour `KeychainSigner` depends on.
///
/// Putting the raw `SecItem*` calls behind this seam keeps the signer's logic
/// testable against an in-memory double: CI machines run with locked or headless
/// keychains, so the concrete `SystemKeychainStore` is never exercised in tests.
protocol KeychainStore: Sendable {
    /// Persists `secret` under `account`, replacing any value already there.
    func save(_ secret: Data, account: String) throws
    /// The value stored under `account`, or `nil` when none exists.
    func load(account: String) throws -> Data?
    /// Removes the value under `account`; a missing value is not an error.
    func delete(account: String) throws
}

/// The real Keychain, holding each secret as a generic-password item.
///
/// Items are pinned to this device and never synchronised to iCloud: the
/// `kSecAttrSynchronizable` attribute is deliberately absent, and accessibility
/// is `AfterFirstUnlockThisDeviceOnly`, so the key is reachable to background work
/// once the device has been unlocked at least once since boot yet never leaves
/// the device. `kSecUseDataProtectionKeychain` is set on every call so the same
/// guarantees hold on macOS, where items otherwise land in the legacy file-based
/// keychain that ignores `kSecAttrAccessible`. Replacing a key updates the item
/// in place — the stored value never passes through a deleted state, so a crash
/// mid-replacement cannot destroy the only copy of an identity key.
struct SystemKeychainStore: KeychainStore {
    let service: String

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    func save(_ secret: Data, account: String) throws {
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = secret
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: secret,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let updateStatus = SecItemUpdate(
                baseQuery(account: account) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess: return item as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError.unexpectedStatus(status)
        }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}

/// An `EventSigner` whose secret key lives in the Keychain.
///
/// One instance addresses one stored key, named by `account` within `service`; an
/// app holding several identities uses one signer per account. The key is loaded
/// fresh for each operation rather than cached, so a key deleted out from under
/// the signer surfaces as `KeychainError.keyNotFound` on the next call instead of
/// signing with a stale secret.
public struct KeychainSigner: EventSigner {
    private let keychain: any KeychainStore
    private let account: String

    /// The default Keychain service namespace for stored identities.
    public static let defaultService = "chat.buzz.nostrcore.identity"

    /// Creates a signer backed by the system Keychain.
    public init(account: String, service: String = KeychainSigner.defaultService) {
        self.init(account: account, keychain: SystemKeychainStore(service: service))
    }

    /// Creates a signer over a supplied store — the injection seam tests use.
    init(account: String, keychain: any KeychainStore) {
        self.account = account
        self.keychain = keychain
    }

    // MARK: - Key custody

    /// Stores `key`, replacing any key already held for this account.
    public func store(_ key: PrivateKey) throws {
        try keychain.save(key.rawRepresentation, account: account)
    }

    /// The stored key, or `nil` when this account holds none.
    ///
    /// Throws `KeychainError.storedKeyInvalid` if a value is present but is not a
    /// valid 32-byte scalar — corruption worth surfacing rather than swallowing.
    public func loadPrivateKey() throws -> PrivateKey? {
        guard let data = try keychain.load(account: account) else { return nil }
        guard let key = try? PrivateKey(rawRepresentation: data) else {
            throw KeychainError.storedKeyInvalid
        }
        return key
    }

    /// Removes the stored key; a missing key is not an error.
    public func delete() throws {
        try keychain.delete(account: account)
    }

    // MARK: - EventSigner

    public func publicKey() async throws -> PublicKey {
        try requireKey().publicKey
    }

    public func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent {
        guard !kind.isRelaySigned else { throw SigningError.relaySignedKind(kind) }
        return try NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: createdAt,
            with: requireKey()
        )
    }

    private func requireKey() throws -> PrivateKey {
        guard let key = try loadPrivateKey() else { throw KeychainError.keyNotFound }
        return key
    }
}

/// Errors from Keychain-backed key custody.
public enum KeychainError: Error, Equatable {
    /// No key is stored for the signer's account.
    case keyNotFound
    /// A stored value existed but was not a valid 32-byte secp256k1 scalar.
    case storedKeyInvalid
    /// A `SecItem*` call failed with an unexpected `OSStatus`.
    case unexpectedStatus(OSStatus)
}
