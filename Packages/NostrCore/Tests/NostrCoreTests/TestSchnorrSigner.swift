import Foundation
@testable import NostrCore
import P256K

/// Test-only BIP-340 Schnorr signing over P256K, used to mint signed fixtures.
///
/// The production layer in this step verifies signatures but ships no signing
/// path, so the ability to create a signed event lives here in the test target.
enum TestSchnorrSigner {
    /// A generated or imported secp256k1 identity for signing test events.
    struct Identity {
        let privateKey: P256K.Schnorr.PrivateKey

        var publicKeyXOnly: Data {
            Data(privateKey.xonly.bytes)
        }

        var publicKeyHex: String {
            publicKeyXOnly.hexString
        }
    }

    /// A random identity from the system CSPRNG.
    static func makeIdentity() -> Identity {
        guard let key = try? P256K.Schnorr.PrivateKey() else {
            fatalError("secp256k1 key generation failed")
        }
        return Identity(privateKey: key)
    }

    /// An identity from a fixed 32-byte secret, for deterministic fixtures.
    static func makeIdentity(secretHex: String) -> Identity {
        guard let secret = Data(hexString: secretHex),
              let key = try? P256K.Schnorr.PrivateKey(dataRepresentation: secret)
        else {
            fatalError("invalid test secret key: \(secretHex)")
        }
        return Identity(privateKey: key)
    }

    /// Signs a 32-byte message with fresh BIP-340 auxiliary randomness.
    static func sign(message: Data, with identity: Identity) -> Data {
        precondition(message.count == 32, "Schnorr message must be 32 bytes")
        var messageBytes = Array(message)
        var auxiliary = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &auxiliary)
        do {
            let signature = try auxiliary.withUnsafeMutableBytes { buffer in
                try identity.privateKey.signature(
                    message: &messageBytes,
                    auxiliaryRand: buffer.baseAddress,
                    strict: true
                )
            }
            return signature.dataRepresentation
        } catch {
            fatalError("Schnorr signing failed: \(error)")
        }
    }

    /// Builds a fully signed event carrying a valid id and signature.
    static func signedEvent(
        kind: EventKind,
        content: String,
        tags: [[String]] = [],
        createdAt: Int64 = 1_700_000_000,
        with identity: Identity
    ) -> NostrEvent {
        let pubkey = identity.publicKeyHex
        let idBytes = NostrEvent.computeID(
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content
        )
        let signature = sign(message: idBytes, with: identity)
        return NostrEvent(
            id: idBytes.hexString,
            pubkey: pubkey,
            createdAt: createdAt,
            kind: kind,
            tags: tags,
            content: content,
            sig: signature.hexString
        )
    }
}
