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
/// The gateway computes `SHA-256("{domain}\n{transcript_json}")` and verifies
/// that the attestation or assertion binds to the same hash. The client must
/// reproduce this exactly.
enum AppAttestClientData {
    private static let enrollDomain = "buzz.push.enroll.v1"
    private static let delegateDomain = "buzz.push.delegate.v1"

    /// Client data hash for the enrollment attestation.
    static func enrollHash(transcript: EnrollTranscript) -> Data {
        transcriptHash(domain: enrollDomain, transcript: transcript)
    }

    /// Client data hash for the delegation assertion.
    static func delegateHash(transcript: DelegateTranscript) -> Data {
        transcriptHash(domain: delegateDomain, transcript: transcript)
    }

    private static func transcriptHash(domain: String, transcript: some Encodable) -> Data {
        // JSONEncoder without .sortedKeys preserves CodingKeys declaration order,
        // which matches the Rust struct field order (serde_json default).
        let encoder = JSONEncoder()
        let json: Data
        do {
            json = try encoder.encode(transcript)
        } catch {
            // Transcript types are fully concrete — encoding cannot fail.
            fatalError("Failed to encode transcript: \(error)")
        }
        let payload = "\(domain)\n".data(using: .utf8)! + json
        let digest = SHA256.hash(data: payload)
        return Data(digest)
    }
}
