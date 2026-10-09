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
/// 1. **Challenge** (`POST /v1/installations/challenge`): the gateway returns a
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
    private let baseURL: URL

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
        let url = baseURL.appendingPathComponent("v1/installations/challenge")
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
            deviceToken: request.deviceToken,
            attestation: request.attestation,
            keyID: request.keyID,
            challengeID: request.challengeID,
            appProfile: request.appProfile
        )
        let body = try JSONEncoder().encode(wire)
        let (data, status) = try await post(body: body, to: url, signer: signer)
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
            installationID: request.installationID,
            relayURL: request.relayURL,
            relayPubkey: request.relayPubkey
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

struct GatewayChallengeRequest: Encodable, Sendable {}

/// The gateway's answer to a challenge request.
public struct GatewayChallengeResponse: Codable, Equatable, Sendable {
    /// The challenge identifier to reference in the installation request.
    public let challengeID: String
    /// The nonce string to include in the App Attest client data hash.
    public let challenge: String

    private enum CodingKeys: String, CodingKey {
        case challengeID = "challenge_id"
        case challenge
    }
}

// MARK: - Installation types

/// The values needed to register a device with the gateway.
public struct GatewayInstallRequest: Equatable, Sendable {
    /// The raw APNs device token as hex.
    public let deviceToken: String
    /// The App Attest attestation object (base64).
    public let attestation: String
    /// The App Attest key identifier.
    public let keyID: String
    /// The challenge identifier from step 1.
    public let challengeID: String
    /// The app profile string (e.g. `"buzz-ios-dogfood"`).
    public let appProfile: String

    public init(
        deviceToken: String,
        attestation: String,
        keyID: String,
        challengeID: String,
        appProfile: String
    ) {
        self.deviceToken = deviceToken
        self.attestation = attestation
        self.keyID = keyID
        self.challengeID = challengeID
        self.appProfile = appProfile
    }
}

/// Wire encoding for the installation request body.
struct GatewayInstallWire: Encodable, Sendable {
    let deviceToken: String
    let attestation: String
    let keyID: String
    let challengeID: String
    let appProfile: String

    private enum CodingKeys: String, CodingKey {
        case deviceToken = "device_token"
        case attestation
        case keyID = "key_id"
        case challengeID = "challenge_id"
        case appProfile = "app_profile"
    }
}

/// The gateway's answer to an installation request.
public struct GatewayInstallResponse: Codable, Equatable, Sendable {
    /// The installation handle this device uses for all subsequent calls.
    public let installationID: String

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
    }
}

// MARK: - Delegation types

/// The values needed to delegate an installation to a relay.
public struct GatewayDelegationRequest: Equatable, Sendable {
    public let installationID: String
    public let relayURL: String
    public let relayPubkey: String

    public init(installationID: String, relayURL: String, relayPubkey: String) {
        self.installationID = installationID
        self.relayURL = relayURL
        self.relayPubkey = relayPubkey
    }
}

/// Wire encoding for the delegation request body.
struct GatewayDelegationWire: Encodable, Sendable {
    let installationID: String
    let relayURL: String
    let relayPubkey: String

    private enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case relayURL = "relay_url"
        case relayPubkey = "relay_pubkey"
    }
}

/// The gateway's answer to a delegation request.
public struct GatewayDelegationResponse: Codable, Equatable, Sendable {
    /// The delegation grant the relay accepts as proof of push authorisation.
    public let delegationID: String

    private enum CodingKeys: String, CodingKey {
        case delegationID = "delegation_id"
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
}

// MARK: - Wire shapes

struct GatewayErrorEnvelope: Decodable {
    let error: String?
}

// MARK: - Protocol constants (NIP-PL)

/// NIP-PL audience URLs used in push lease events. These are protocol constants
/// that identify the gateway's capability, not actual endpoint URLs.
public enum NIPPLAudience {
    public static let installations = "https://push.buzz.xyz/v1/installations"
    public static let delegations = "https://push.buzz.xyz/v1/delegations"
}

/// Push enrollment constants.
public enum PushConstants {
    /// The app profile string the gateway expects from this client.
    public static let appProfile = "buzz-ios-dogfood"
    /// The push gateway's HTTP base URL (tailnet deployment).
    /// Will move to relay-info discovery once the gateway advertises itself.
    public static let gatewayURL = URL(string: "http://100.111.202.55:3005")!
}
