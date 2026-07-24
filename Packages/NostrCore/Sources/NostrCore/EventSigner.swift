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
}

/// Errors raised while signing an event.
public enum SigningError: Error, Equatable {
    /// The relay authors and signs this kind itself, so a signer refuses to
    /// produce a client-signed one the relay would only reject.
    case relaySignedKind(EventKind)
}
