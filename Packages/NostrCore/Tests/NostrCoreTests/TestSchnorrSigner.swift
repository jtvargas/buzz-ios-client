import Foundation
@testable import NostrCore

/// Test-only convenience for minting signed fixtures.
///
/// This is a thin shim over the production signing path: it holds a `PrivateKey`
/// and forwards to `PrivateKey.signature(for:)` and `NostrEvent.signed(...)`, so
/// the fixtures exercised by the step-1 suites now run through exactly the code
/// this step ships rather than a duplicated signing routine. Failures trap
/// because a fixture that cannot be signed is a test-authoring bug.
enum TestSchnorrSigner {
    /// A secp256k1 identity for signing test events.
    struct Identity {
        let privateKey: PrivateKey

        var publicKeyXOnly: Data {
            privateKey.publicKey.rawRepresentation
        }

        var publicKeyHex: String {
            privateKey.publicKey.hex
        }
    }

    /// A random identity from the system CSPRNG.
    static func makeIdentity() -> Identity {
        guard let key = try? PrivateKey() else {
            fatalError("secp256k1 key generation failed")
        }
        return Identity(privateKey: key)
    }

    /// An identity from a fixed 32-byte secret, for deterministic fixtures.
    static func makeIdentity(secretHex: String) -> Identity {
        guard let key = try? PrivateKey(hex: secretHex) else {
            fatalError("invalid test secret key: \(secretHex)")
        }
        return Identity(privateKey: key)
    }

    /// Signs a 32-byte message with fresh BIP-340 auxiliary randomness.
    static func sign(message: Data, with identity: Identity) -> Data {
        guard let signature = try? identity.privateKey.signature(for: message) else {
            fatalError("Schnorr signing failed for a valid identity")
        }
        return signature
    }

    /// Builds a fully signed event carrying a valid id and signature.
    static func signedEvent(
        kind: EventKind,
        content: String,
        tags: [[String]] = [],
        createdAt: Int64 = 1_700_000_000,
        with identity: Identity
    ) -> NostrEvent {
        guard let event = try? NostrEvent.signed(
            kind: kind,
            content: content,
            tags: tags,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            with: identity.privateKey
        ) else {
            fatalError("failed to sign fixture event")
        }
        return event
    }
}
