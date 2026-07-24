import Foundation
@testable import NostrCore
import Testing

/// An in-memory stand-in for the Keychain.
///
/// The signer's custody logic is exercised through this double so no test touches
/// a real keychain — CI machines run with locked or headless keychains where
/// `SecItem*` calls fail or block. A lock keeps it safe to hand to `Sendable`
/// call sites even though the tests here are single-threaded.
private final class InMemoryKeychain: KeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data]

    init(seeded: [String: Data] = [:]) {
        items = seeded
    }

    func save(_ secret: Data, account: String) throws {
        lock.withLock { items[account] = secret }
    }

    func load(account: String) throws -> Data? {
        lock.withLock { items[account] }
    }

    func delete(account: String) throws {
        lock.withLock { _ = items.removeValue(forKey: account) }
    }
}

@Suite("Keychain-backed signer")
struct KeychainSignerTests {
    private let account = "alice@relay.example"

    @Test("A stored key loads back byte-for-byte")
    func storeThenLoad() throws {
        let signer = KeychainSigner(account: account, keychain: InMemoryKeychain())
        let key = try PrivateKey()
        try signer.store(key)
        let loaded = try #require(try signer.loadPrivateKey())
        #expect(loaded.rawRepresentation == key.rawRepresentation)
    }

    @Test("The signer signs valid events attributed to the stored key")
    func signWithStoredKey() async throws {
        let signer = KeychainSigner(account: account, keychain: InMemoryKeychain())
        let key = try PrivateKey()
        try signer.store(key)

        let event = try await signer.sign(kind: .textNote, content: "from the keychain")
        #expect(event.isValid)
        #expect(event.pubkey == key.publicKey.hex)

        let publicKey = try await signer.publicKey()
        #expect(publicKey == key.publicKey)
    }

    @Test("Deleting a key makes it unavailable")
    func deleteRemovesKey() async throws {
        let signer = KeychainSigner(account: account, keychain: InMemoryKeychain())
        try signer.store(PrivateKey())
        try signer.delete()

        #expect(try signer.loadPrivateKey() == nil)
        await #expect(throws: KeychainError.keyNotFound) {
            _ = try await signer.publicKey()
        }
    }

    @Test("Signing with no stored key reports the missing key")
    func missingKeyPath() async throws {
        let signer = KeychainSigner(account: account, keychain: InMemoryKeychain())
        #expect(try signer.loadPrivateKey() == nil)
        await #expect(throws: KeychainError.keyNotFound) {
            try await signer.sign(kind: .textNote, content: "no key here")
        }
    }

    @Test("A corrupt stored value is reported, not signed with")
    func corruptStoredValue() throws {
        let keychain = InMemoryKeychain(seeded: [account: Data([0x01, 0x02, 0x03])])
        let signer = KeychainSigner(account: account, keychain: keychain)
        #expect(throws: KeychainError.storedKeyInvalid) {
            _ = try signer.loadPrivateKey()
        }
    }

    @Test("The signer refuses relay-signed kinds even with a key present")
    func refusesRelaySignedKinds() async throws {
        let signer = KeychainSigner(account: account, keychain: InMemoryKeychain())
        try signer.store(PrivateKey())
        await #expect(throws: SigningError.relaySignedKind(.memberAdded)) {
            try await signer.sign(kind: .memberAdded, content: "the relay's job")
        }
    }
}
