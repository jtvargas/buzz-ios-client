@testable import Hive
import NostrCore
import Testing

/// Key reveal is gated on device authentication: revealed only on success, and
/// otherwise the secret stays hidden.
@MainActor
@Suite struct KeyBackupModelTests {
    static let priv = "3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b"

    private struct StubAuth: DeviceAuthenticating {
        let granted: Bool
        func authenticate(reason _: String) async -> Bool { granted }
    }

    @Test func revealsSecretOnSuccessfulAuth() async throws {
        let key = try PrivateKey(hex: Self.priv)
        let model = KeyBackupModel(
            selfPubkey: key.publicKey.hex,
            authenticator: StubAuth(granted: true),
            loadKey: { key }
        )
        await model.revealSecret()
        #expect(model.revealedNsec == key.nsec)
        #expect(model.isRevealed)
        #expect(!model.revealFailed)
    }

    @Test func keepsSecretHiddenOnDeniedAuth() async throws {
        let key = try PrivateKey(hex: Self.priv)
        let model = KeyBackupModel(
            selfPubkey: key.publicKey.hex,
            authenticator: StubAuth(granted: false),
            loadKey: { key }
        )
        await model.revealSecret()
        #expect(model.revealedNsec == nil)
        #expect(model.revealFailed)
    }

    @Test func failsWhenNoKeyIsStored() async throws {
        let key = try PrivateKey(hex: Self.priv)
        let model = KeyBackupModel(
            selfPubkey: key.publicKey.hex,
            authenticator: StubAuth(granted: true),
            loadKey: { nil }
        )
        await model.revealSecret()
        #expect(model.revealedNsec == nil)
        #expect(model.revealFailed)
    }

    @Test func hideClearsRevealedSecret() async throws {
        let key = try PrivateKey(hex: Self.priv)
        let model = KeyBackupModel(
            selfPubkey: key.publicKey.hex,
            authenticator: StubAuth(granted: true),
            loadKey: { key }
        )
        await model.revealSecret()
        model.hideSecret()
        #expect(model.revealedNsec == nil)
    }
}

/// The store-ownership decision that drives wipe-on-identity-change at login.
/// Serialized because it mutates a shared `UserDefaults` key.
@Suite(.serialized)
struct StoreOwnershipTests {
    @Test func freshInstallKeepsTheStore() {
        let previous = StoreOwnership.ownerPubkeyHex
        defer { StoreOwnership.ownerPubkeyHex = previous }
        StoreOwnership.ownerPubkeyHex = nil
        #expect(!StoreOwnership.shouldWipe(forIncoming: "abc"))
    }

    @Test func sameKeyReloginKeepsTheStore() {
        let previous = StoreOwnership.ownerPubkeyHex
        defer { StoreOwnership.ownerPubkeyHex = previous }
        StoreOwnership.ownerPubkeyHex = "abc"
        #expect(!StoreOwnership.shouldWipe(forIncoming: "abc"))
    }

    @Test func differentKeyWipesTheStore() {
        let previous = StoreOwnership.ownerPubkeyHex
        defer { StoreOwnership.ownerPubkeyHex = previous }
        StoreOwnership.ownerPubkeyHex = "abc"
        #expect(StoreOwnership.shouldWipe(forIncoming: "xyz"))
    }
}
