import Foundation

/// A source of signed events for one identity.
///
/// The production signer reads its key from the Keychain, which can block and can
/// fail, so the protocol is `async throws` even though an in-memory signer needs
/// neither. Signing code should depend on this abstraction rather than on
/// `PrivateKey` directly, so the secret never has to travel to the call site that
/// happens to sign.
public protocol EventSigner: Sendable {
    /// The identity these signatures are attributed to.
    func publicKey() async throws -> PublicKey

    /// Builds and signs an event with the given fields, stamped at `createdAt`.
    func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent

    /// NIP-44 encrypts `plaintext` to the signer's own identity — the
    /// `conversationKey(self, self)` encrypt-to-self construction private,
    /// replaceable app data (NIP-78/NIP-RS read state) uses so its content is
    /// readable only by this keypair.
    ///
    /// A default implementation throws ``SigningError/selfEncryptionUnsupported``:
    /// only signers that hold the secret (the in-memory and Keychain signers) can
    /// derive the conversation key, so a test double that never touches encrypted
    /// app data need not implement it.
    func encryptToSelf(_ plaintext: String) async throws -> String

    /// NIP-44 decrypts a payload this identity produced with ``encryptToSelf(_:)``
    /// (or a peer instance of the same identity did, e.g. another device's
    /// read-state blob). Default implementation throws
    /// ``SigningError/selfEncryptionUnsupported``.
    func decryptToSelf(_ ciphertext: String) async throws -> String
}

public extension EventSigner {
    /// Signs at the current instant — what almost every call site wants.
    func sign(
        kind: EventKind,
        content: String,
        tags: [[String]] = []
    ) async throws -> NostrEvent {
        try await sign(kind: kind, content: content, tags: tags, createdAt: Date())
    }

    func encryptToSelf(_: String) async throws -> String {
        throw SigningError.selfEncryptionUnsupported
    }

    func decryptToSelf(_: String) async throws -> String {
        throw SigningError.selfEncryptionUnsupported
    }
}

/// A signer that keeps its key in memory.
///
/// Suited to tests and to the short onboarding window between generating a key
/// and committing it to the Keychain. Durable use in the app should go through
/// the Keychain-backed signer instead.
public struct InMemorySigner: EventSigner {
    private let key: PrivateKey

    public init(_ key: PrivateKey) {
        self.key = key
    }

    /// Generates a fresh identity.
    public init() throws {
        key = try PrivateKey()
    }

    public func publicKey() async throws -> PublicKey {
        key.publicKey
    }

    public func sign(
        kind: EventKind,
        content: String,
        tags: [[String]],
        createdAt: Date
    ) async throws -> NostrEvent {
        guard !kind.isRelaySigned else { throw SigningError.relaySignedKind(kind) }
        return try NostrEvent.signed(kind: kind, content: content, tags: tags, createdAt: createdAt, with: key)
    }

    public func encryptToSelf(_ plaintext: String) async throws -> String {
        try NIP44.encrypt(plaintext, conversationKey: NIP44.conversationKey(privateKey: key, peer: key.publicKey))
    }

    public func decryptToSelf(_ ciphertext: String) async throws -> String {
        try NIP44.decrypt(ciphertext, conversationKey: NIP44.conversationKey(privateKey: key, peer: key.publicKey))
    }
}

/// Errors raised while signing an event.
public enum SigningError: Error, Equatable {
    /// The relay authors and signs this kind itself, so a signer refuses to
    /// produce a client-signed one the relay would only reject.
    case relaySignedKind(EventKind)
    /// The signer cannot encrypt or decrypt to self because it does not hold the
    /// secret key (a signature-only or scripted signer). Real signers — in-memory
    /// and Keychain-backed — implement the NIP-44 to-self path.
    case selfEncryptionUnsupported
}
