import CryptoKit
import Foundation

/// A source of App Attest keys and attestations. Abstracted so enrollment is
/// testable without a physical device — ``DCAppAttestService`` does not work on
/// the simulator.
///
/// The production implementation wraps `DCAppAttestService`; tests inject a
/// fake that returns scripted values.
public protocol AppAttestProviding: Sendable {
    /// Whether App Attest is supported on this device.
    var isSupported: Bool { get }

    /// Generates a new App Attest key and returns its identifier.
    func generateKey() async throws -> String

    /// Produces an attestation for the given key over `clientDataHash`.
    ///
    /// - Parameters:
    ///   - keyID: the key identifier from ``generateKey()``.
    ///   - clientDataHash: the SHA-256 of the challenge transcript the gateway
    ///     requires attested.
    /// - Returns: the attestation object as raw bytes.
    func attest(keyID: String, clientDataHash: Data) async throws -> Data

    /// Produces an assertion for the given key over `clientDataHash`.
    ///
    /// Used for subsequent authenticated requests after initial attestation.
    func assert(keyID: String, clientDataHash: Data) async throws -> Data
}

// MARK: - Production provider (iOS only)

#if canImport(DeviceCheck)
import DeviceCheck

/// The production App Attest provider: a thin, honest wrapper over
/// `DCAppAttestService.shared`.
///
/// Exists as a struct rather than a protocol extension on `DCAppAttestService`
/// so the concrete type can be named without the protocol — the composition root
/// creates one of these, and test doubles create their own conformer.
public struct DeviceAppAttestProvider: AppAttestProviding {
    public init() {}

    public var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attest(keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    public func assert(keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}
#endif

// MARK: - Client data hash

/// Builds the client data hash the gateway expects for App Attest.
///
/// The challenge response from the gateway carries a nonce string; the
/// attestation binds to the SHA-256 of that nonce — so both sides agree on what
/// was attested.
public enum AppAttestClientData {
    /// SHA-256 of the challenge nonce, suitable for `attest(keyID:clientDataHash:)`.
    public static func hash(challenge: String) -> Data {
        let data = Data(challenge.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest)
    }
}
