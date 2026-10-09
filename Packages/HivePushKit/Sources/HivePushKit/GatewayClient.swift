import Foundation
import NostrCore

/// The push gateway's enrollment HTTP surface: challenge, installation, delegation.
///
/// Follows the same pattern as `BuzzKit/WindowClient` and `BuzzKit/InviteClient`:
/// a stateless struct over an injected ``HTTPTransport``, with status-as-data for
/// HTTP responses and each endpoint expressed as one throwing function.
///
/// # The three-step enrollment
///
/// 1. **Challenge** (`POST /v1/installations/challenges`): the gateway returns a
///    nonce this device must attest.
/// 2. **Installation** (`POST /v1/installations`): the device sends its APNs token,
///    the App Attest attestation over the challenge, and an app profile identifier.
///    The gateway returns an installation handle.
/// 3. **Delegation** (`POST /v1/delegations`): the device delegates the
///    installation to a specific relay's pubkey. The gateway returns a delegation
///    grant the relay will accept.
///
/// All three routes require NIP-98 authentication: each request carries a
/// `Nostr <base64-event>` header signed by the device's identity key.
public struct GatewayClient: Sendable {
    private let transport: any HTTPTransport
    /// The gateway's HTTP root. Credentials the gateway issues (installation
    /// handles, App Attest keys) are only meaningful back at this URL.
    public let baseURL: URL

    /// - Parameters:
    ///   - baseURL: the gateway's HTTP root (e.g. `http://100.111.202.55:3005`).
    ///   - transport: the HTTP seam; `URLSessionHTTPTransport` in production.
    public init(baseURL: URL, transport: any HTTPTransport) {
        self.baseURL = baseURL
        self.transport = transport
    }

    // MARK: - 1. Challenge

    /// Requests a challenge nonce from the gateway.
    public func challenge(signer: some EventSigner) async throws -> GatewayChallengeResponse {
        let url = baseURL.appendingPathComponent("v1/installations/challenges")
        let body = try JSONEncoder().encode(GatewayChallengeRequest())
        let (data, status) = try await post(body: body, to: url, signer: signer)
        guard (200 ... 299).contains(status) else {
            throw GatewayError.httpStatus(status, Self.errorMessage(from: data))
        }
        guard let response = try? JSONDecoder().decode(GatewayChallengeResponse.self, from: data) else {
            throw GatewayError.unreadableResponse
        }
        return response
    }

    // MARK: - 2. Installation

    /// Enrolls this device's push token with the gateway, proving genuine
    /// installation via App Attest.
    public func install(
        _ request: GatewayInstallRequest,
        signer: some EventSigner
    ) async throws -> GatewayInstallResponse {
        let url = baseURL.appendingPathComponent("v1/installations")
        let wire = GatewayInstallWire(
            challengeID: request.challengeID,
            challenge: request.challenge,
            keyID: request.keyID,
            attestation: request.attestation,
            appProfile: request.appProfile,
            endpoint: request.endpoint,
            endpointEpoch: request.endpointEpoch,
            expiresAt: request.expiresAt
        )
        let body = try JSONEncoder().encode(wire)
        let (data, status) = try await post(body: body, to: url, signer: signer)
        if status == 409 {
            throw GatewayError.installationConflict
        }
        guard (200 ... 299).contains(status) else {
            throw GatewayError.httpStatus(status, Self.errorMessage(from: data))
        }
        guard let response = try? JSONDecoder().decode(GatewayInstallResponse.self, from: data) else {
            throw GatewayError.unreadableResponse
        }
        return response
    }

    // MARK: - 3. Delegation

    /// Delegates the installation to a relay identified by its pubkey.
    ///
    /// The gateway returns a delegation grant the relay uses to verify this device
    /// is authorised to receive pushes through it.
    public func delegate(
        _ request: GatewayDelegationRequest,
        signer: some EventSigner
    ) async throws -> GatewayDelegationResponse {
        let url = baseURL.appendingPathComponent("v1/delegations")
        let wire = GatewayDelegationWire(
            challengeID: request.challengeID,
            challenge: request.challenge,
            installationHandle: request.installationHandle,
            endpointEpoch: request.endpointEpoch,
            generation: request.generation,
            relayPubkey: request.relayPubkey,
            notBefore: request.notBefore,
            expiresAt: request.expiresAt,
            assertion: request.assertion
        )
        let body = try JSONEncoder().encode(wire)
        let (data, status) = try await post(body: body, to: url, signer: signer)
        guard (200 ... 299).contains(status) else {
            throw GatewayError.httpStatus(status, Self.errorMessage(from: data))
        }
        guard let response = try? JSONDecoder().decode(GatewayDelegationResponse.self, from: data) else {
            throw GatewayError.unreadableResponse
        }
        return response
    }

    // MARK: - 4. Revocation

    /// Revokes an installation on the gateway (`POST /v1/installations/revoke`).
    ///
    /// The gateway only honours a revocation signed by the installation's own App
    /// Attest key: the body carries a fresh challenge and an assertion over
    /// ``RevokeInstallationTranscript``. There is no handle-only revoke — the
    /// gateway parses the body strictly and rejects anything short of this shape.
    public func revokeInstallation(
        _ request: GatewayRevokeRequest,
        signer: some EventSigner
    ) async throws {
        let url = baseURL.appendingPathComponent("v1/installations/revoke")
        let wire = GatewayRevokeWire(
            challengeID: request.challengeID,
            challenge: request.challenge,
            installationHandle: request.installationHandle,
            endpointEpoch: request.endpointEpoch,
            newEndpointEpoch: request.newEndpointEpoch,
            assertion: request.assertion
        )
        let body = try JSONEncoder().encode(wire)
        let (data, status) = try await post(body: body, to: url, signer: signer)
        guard (200 ... 299).contains(status) else {
            throw GatewayError.httpStatus(status, Self.errorMessage(from: data))
        }
    }

    // MARK: - Internal

    /// Issues a NIP-98-authenticated POST.
    private func post(
        body: Data,
        to url: URL,
        signer: some EventSigner
    ) async throws -> (Data, Int) {
        let authorization = try await NIP98.authorizationHeader(
            url: url,
            method: "POST",
            body: body,
            signer: signer
        )
        let headers = [
            "Content-Type": "application/json",
            "Authorization": authorization,
        ]
        do {
            return try await transport.post(body: body, to: url, headers: headers)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw GatewayError.unreachable(String(describing: error))
        }
    }

    private static func errorMessage(from body: Data) -> String? {
        (try? JSONDecoder().decode(GatewayErrorEnvelope.self, from: body))?.error
    }
}

// MARK: - Challenge types

struct GatewayChallengeRequest: Encodable, Sendable {
    let v: UInt8 = 1
}

/// The gateway's answer to a challenge request.
public struct GatewayChallengeResponse: Codable, Equatable, Sendable {
    /// The challenge identifier to reference in the installation request.
    public let challengeID: String
    /// The nonce string to include in the App Attest client data hash.
    public let challenge: String
    /// Unix timestamp when this challenge expires.
    public let expiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
        case expiresAt = "expires_at"
    }
}

// MARK: - Installation types

/// The values needed to register a device with the gateway.
public struct GatewayInstallRequest: Equatable, Sendable {
    /// The challenge identifier from step 1.
    public let challengeID: String
    /// The challenge nonce from step 1.
    public let challenge: String
    /// The App Attest key identifier (base64).
    public let keyID: String
    /// The App Attest attestation object (base64).
    public let attestation: String
    /// The app profile string (e.g. `"buzz-ios-dogfood"`).
    public let appProfile: String
    /// The raw APNs device token as lowercase hex.
    public let endpoint: String
    /// Endpoint epoch; must be 1 for initial enrollment.
    public let endpointEpoch: Int64
    /// Unix timestamp when this installation expires.
    public let expiresAt: Int64

    public init(
        challengeID: String,
        challenge: String,
        keyID: String,
        attestation: String,
        appProfile: String,
        endpoint: String,
        endpointEpoch: Int64,
        expiresAt: Int64
    ) {
        self.challengeID = challengeID
        self.challenge = challenge
        self.keyID = keyID
        self.attestation = attestation
        self.appProfile = appProfile
        self.endpoint = endpoint
        self.endpointEpoch = endpointEpoch
        self.expiresAt = expiresAt
    }
}

/// Wire encoding for the installation request body.
struct GatewayInstallWire: Encodable, Sendable {
    let v: UInt8 = 1
    let challengeID: String
    let challenge: String
    let keyID: String
    let attestation: String
    let appProfile: String
    let endpoint: String
    let endpointEpoch: Int64
    let expiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case v
        case challengeID = "challenge_id"
        case challenge
        case keyID = "key_id"
        case attestation
        case appProfile = "app_profile"
        case endpoint
        case endpointEpoch = "endpoint_epoch"
        case expiresAt = "expires_at"
    }
}

/// The gateway's answer to an installation request.
public struct GatewayInstallResponse: Codable, Equatable, Sendable {
    /// The installation handle this device uses for all subsequent calls.
    public let installationHandle: String
    /// The endpoint epoch the gateway recorded.
    public let endpointEpoch: Int64
    /// Unix timestamp when this installation expires.
    public let expiresAt: Int64

    private enum CodingKeys: String, CodingKey {
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case expiresAt = "expires_at"
    }
}

// MARK: - Delegation types

/// The values needed to delegate an installation to a relay.
public struct GatewayDelegationRequest: Equatable, Sendable {
    /// The challenge identifier from a fresh challenge request.
    public let challengeID: String
    /// The challenge nonce.
    public let challenge: String
    /// The installation handle from the enroll response.
    public let installationHandle: String
    /// Endpoint epoch; must be ≥ 1.
    public let endpointEpoch: Int64
    /// Delegation generation; must be ≥ 1.
    public let generation: Int64
    /// The relay's 32-byte public key as 64-char lowercase hex.
    public let relayPubkey: String
    /// Unix timestamp for delegation start; must be ≤ now + 300.
    public let notBefore: Int64
    /// Unix timestamp when this delegation expires.
    public let expiresAt: Int64
    /// The App Attest assertion over the delegation transcript (base64).
    public let assertion: String

    public init(
        challengeID: String,
        challenge: String,
        installationHandle: String,
        endpointEpoch: Int64,
        generation: Int64,
        relayPubkey: String,
        notBefore: Int64,
        expiresAt: Int64,
        assertion: String
    ) {
        self.challengeID = challengeID
        self.challenge = challenge
        self.installationHandle = installationHandle
        self.endpointEpoch = endpointEpoch
        self.generation = generation
        self.relayPubkey = relayPubkey
        self.notBefore = notBefore
        self.expiresAt = expiresAt
        self.assertion = assertion
    }
}

/// Wire encoding for the delegation request body.
struct GatewayDelegationWire: Encodable, Sendable {
    let v: UInt8 = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let generation: Int64
    let relayPubkey: String
    let notBefore: Int64
    let expiresAt: Int64
    let assertion: String

    private enum CodingKeys: String, CodingKey {
        case v
        case challengeID = "challenge_id"
        case challenge
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case generation
        case relayPubkey = "relay_pubkey"
        case notBefore = "not_before"
        case expiresAt = "expires_at"
        case assertion
    }
}

/// The gateway's answer to a delegation request.
public struct GatewayDelegationResponse: Codable, Equatable, Sendable {
    /// The opaque sealed grant token the relay accepts as proof of push authorisation.
    public let endpointGrant: String

    private enum CodingKeys: String, CodingKey {
        case endpointGrant = "endpoint_grant"
    }
}

// MARK: - Errors

/// Why a gateway enrollment step failed.
public enum GatewayError: Error, Equatable, Sendable {
    /// The gateway was unreachable — transport-level failure.
    case unreachable(String)
    /// The gateway answered with a non-2xx status.
    case httpStatus(Int, String?)
    /// The gateway answered but the body could not be decoded.
    case unreadableResponse
    /// A live installation already exists for this device's token or App Attest
    /// key (HTTP 409). The body is a bare `{"error":"installation_conflict"}` —
    /// the gateway never discloses the existing handle.
    case installationConflict
}

// MARK: - Wire shapes

struct GatewayErrorEnvelope: Decodable {
    let error: String?
}

/// The values needed to revoke an installation.
public struct GatewayRevokeRequest: Equatable, Sendable {
    /// A fresh challenge identifier from ``GatewayClient/challenge(signer:)``.
    public let challengeID: String
    /// The challenge nonce.
    public let challenge: String
    /// The installation being revoked.
    public let installationHandle: String
    /// The installation's current endpoint epoch.
    public let endpointEpoch: Int64
    /// Must be `endpointEpoch + 1`; the gateway records it on the tombstone.
    public let newEndpointEpoch: Int64
    /// App Attest assertion (base64) over ``RevokeInstallationTranscript``.
    public let assertion: String

    public init(
        challengeID: String,
        challenge: String,
        installationHandle: String,
        endpointEpoch: Int64,
        newEndpointEpoch: Int64,
        assertion: String
    ) {
        self.challengeID = challengeID
        self.challenge = challenge
        self.installationHandle = installationHandle
        self.endpointEpoch = endpointEpoch
        self.newEndpointEpoch = newEndpointEpoch
        self.assertion = assertion
    }
}

/// Wire encoding for the revocation request body.
struct GatewayRevokeWire: Encodable, Sendable {
    let v: UInt8 = 1
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let newEndpointEpoch: Int64
    let assertion: String

    private enum CodingKeys: String, CodingKey {
        case v
        case challengeID = "challenge_id"
        case challenge
        case installationHandle = "installation_handle"
        case endpointEpoch = "endpoint_epoch"
        case newEndpointEpoch = "new_endpoint_epoch"
        case assertion
    }
}

// MARK: - Protocol constants (NIP-PL)

/// NIP-PL audience URLs used in push lease events. These are protocol constants
/// that identify the gateway's capability, not actual endpoint URLs.
public enum NIPPLAudience {
    public static let installations = "https://push.buzz.xyz/v1/installations"
    public static let delegations = "https://push.buzz.xyz/v1/delegations"
    public static let revokeInstallation = "https://push.buzz.xyz/v1/installations/revoke"
}

/// Push enrollment constants.
public enum PushConstants {
    /// The app profile string the gateway expects from this client.
    public static let appProfile = "buzz-ios-dogfood"
    /// The push gateway's HTTP base URL (tailnet deployment).
    /// Will move to relay-info discovery once the gateway advertises itself.
    public static let gatewayURL = URL(string: "http://100.111.202.55:3005")!
}

// MARK: - App Attest transcripts

/// The JSON transcript the gateway hashes when verifying the attestation on enrollment.
/// Field order and names must match the gateway's `EnrollTranscript` exactly.
struct EnrollTranscript: CanonicalTranscript {
    let v: UInt8
    let audience: String
    let challengeID: String
    let challenge: String
    let keyID: String
    let appProfile: String
    let endpoint: String
    let endpointEpoch: Int64
    let expiresAt: Int64

    func canonicalJSON() -> Data {
        // Field order matches the Rust struct declaration (serde_json default).
        var s = "{\"v\":\(v)"
        s += ",\"audience\":\(jsonQuote(audience))"
        s += ",\"challenge_id\":\(jsonQuote(challengeID))"
        s += ",\"challenge\":\(jsonQuote(challenge))"
        s += ",\"key_id\":\(jsonQuote(keyID))"
        s += ",\"app_profile\":\(jsonQuote(appProfile))"
        s += ",\"endpoint\":\(jsonQuote(endpoint))"
        s += ",\"endpoint_epoch\":\(endpointEpoch)"
        s += ",\"expires_at\":\(expiresAt)"
        s += "}"
        return Data(s.utf8)
    }
}

/// The JSON transcript the gateway hashes when verifying the assertion on delegation.
/// Field order and names must match the gateway's `DelegateTranscript` exactly.
struct DelegateTranscript: CanonicalTranscript {
    let v: UInt8
    let audience: String
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let generation: Int64
    let relayPubkey: String
    let notBefore: Int64
    let expiresAt: Int64

    func canonicalJSON() -> Data {
        var s = "{\"v\":\(v)"
        s += ",\"audience\":\(jsonQuote(audience))"
        s += ",\"challenge_id\":\(jsonQuote(challengeID))"
        s += ",\"challenge\":\(jsonQuote(challenge))"
        s += ",\"installation_handle\":\(jsonQuote(installationHandle))"
        s += ",\"endpoint_epoch\":\(endpointEpoch)"
        s += ",\"generation\":\(generation)"
        s += ",\"relay_pubkey\":\(jsonQuote(relayPubkey))"
        s += ",\"not_before\":\(notBefore)"
        s += ",\"expires_at\":\(expiresAt)"
        s += "}"
        return Data(s.utf8)
    }
}

/// The JSON transcript the gateway hashes when verifying the assertion on
/// installation revocation. Field order and names must match the gateway's
/// `RevokeInstallationTranscript` exactly.
struct RevokeInstallationTranscript: CanonicalTranscript {
    let v: UInt8
    let audience: String
    let challengeID: String
    let challenge: String
    let installationHandle: String
    let endpointEpoch: Int64
    let newEndpointEpoch: Int64

    func canonicalJSON() -> Data {
        var s = "{\"v\":\(v)"
        s += ",\"audience\":\(jsonQuote(audience))"
        s += ",\"challenge_id\":\(jsonQuote(challengeID))"
        s += ",\"challenge\":\(jsonQuote(challenge))"
        s += ",\"installation_handle\":\(jsonQuote(installationHandle))"
        s += ",\"endpoint_epoch\":\(endpointEpoch)"
        s += ",\"new_endpoint_epoch\":\(newEndpointEpoch)"
        s += "}"
        return Data(s.utf8)
    }
}

// MARK: - Canonical JSON helpers

/// Protocol for transcript types that produce byte-exact JSON matching the
/// gateway's Rust `serde_json` output.
protocol CanonicalTranscript {
    func canonicalJSON() -> Data
}

/// Produces a JSON-quoted string value: wraps in `"`, escapes `\`, `"`, and
/// control characters. Does NOT escape `/` — Rust's serde_json doesn't, and
/// byte-for-byte parity is required for the App Attest clientDataHash.
private func jsonQuote(_ value: String) -> String {
    var out = "\""
    for c in value.unicodeScalars {
        switch c {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\u{08}": out += "\\b"
        case "\u{0C}": out += "\\f"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if c.value < 0x20 {
                out += String(format: "\\u%04x", c.value)
            } else {
                out += String(c)
            }
        }
    }
    out += "\""
    return out
}
