import Foundation
@testable import HivePushKit
import NostrCore
import Testing

/// The gateway client driven against a scripted transport: each endpoint produces
/// the expected request shape, handles non-2xx as data, and turns an unreachable
/// transport into the right error.
@Suite("Gateway client", .timeLimit(.minutes(1)))
struct GatewayClientTests {
    private let baseURL = URL(string: "http://gateway.test:3005")!

    private func signer() throws -> InMemorySigner {
        try InMemorySigner()
    }

    // MARK: - Challenge

    @Test("Challenge decodes a well-formed response")
    func challengeSuccess() async throws {
        let responseJSON = #"{"challenge_id":"ch-123","challenge":"nonce-abc","expires_at":1700000000}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 200),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let response = try await client.challenge(signer: signer())

        #expect(response.challengeID == "ch-123")
        #expect(response.challenge == "nonce-abc")
        #expect(response.expiresAt == 1_700_000_000)

        // Verify request was to the right path.
        let request = transport.requests[0]
        #expect(request.url.path.hasSuffix("/v1/installations/challenges"))
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Authorization"]?.hasPrefix("Nostr ") == true)

        // Verify the request body carries the wire version.
        let bodyJSON = try JSONSerialization.jsonObject(with: request.body) as? [String: Any]
        #expect(bodyJSON?["v"] as? Int == 1)
    }

    @Test("Challenge returns httpStatus on 403")
    func challengeHTTPError() async throws {
        let transport = ScriptedTransport(responses: [
            (Data(#"{"error":"forbidden"}"#.utf8), 403),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)

        await #expect(throws: GatewayError.self) {
            _ = try await client.challenge(signer: self.signer())
        }
    }

    @Test("Challenge returns unreachable on transport failure")
    func challengeTransportFailure() async throws {
        let transport = ScriptedTransport(responses: [], shouldThrow: true)
        let client = GatewayClient(baseURL: baseURL, transport: transport)

        await #expect(throws: GatewayError.self) {
            _ = try await client.challenge(signer: self.signer())
        }
    }

    // MARK: - Installation

    @Test("Install decodes a well-formed response")
    func installSuccess() async throws {
        let responseJSON = #"{"installation_handle":"handle-456","endpoint_epoch":1,"expires_at":1700086400}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 201),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let request = GatewayInstallRequest(
            challengeID: "ch-123",
            challenge: "nonce-abc",
            keyID: "key-1",
            attestation: "base64attest",
            appProfile: "buzz-ios-dogfood",
            endpoint: "aabbccdd",
            endpointEpoch: 1,
            expiresAt: 1_700_086_400
        )
        let response = try await client.install(request, signer: signer())

        #expect(response.installationHandle == "handle-456")
        #expect(response.endpointEpoch == 1)
        #expect(response.expiresAt == 1_700_086_400)

        // Verify the request body was JSON-encoded correctly.
        let sent = transport.requests[0]
        #expect(sent.url.path.hasSuffix("/v1/installations"))
        let bodyJSON = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        #expect(bodyJSON?["v"] as? Int == 1)
        #expect(bodyJSON?["endpoint"] as? String == "aabbccdd")
        #expect(bodyJSON?["key_id"] as? String == "key-1")
        #expect(bodyJSON?["app_profile"] as? String == "buzz-ios-dogfood")
        #expect(bodyJSON?["challenge_id"] as? String == "ch-123")
        #expect(bodyJSON?["challenge"] as? String == "nonce-abc")
        #expect(bodyJSON?["endpoint_epoch"] as? Int == 1)
        #expect(bodyJSON?["expires_at"] as? Int == 1_700_086_400)
        // Must not send the old "device_token" key.
        #expect(bodyJSON?["device_token"] == nil)
    }

    @Test("Install throws installationConflict on a bare 409")
    func installConflict() async throws {
        let conflictJSON = #"{"error":"installation_conflict"}"#
        let transport = ScriptedTransport(responses: [
            (Data(conflictJSON.utf8), 409),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let request = GatewayInstallRequest(
            challengeID: "ch-123",
            challenge: "nonce-abc",
            keyID: "key-1",
            attestation: "base64attest",
            appProfile: "buzz-ios-dogfood",
            endpoint: "aabbccdd",
            endpointEpoch: 1,
            expiresAt: 1_700_086_400
        )
        do {
            _ = try await client.install(request, signer: signer())
            Issue.record("Expected installationConflict error")
        } catch let error as GatewayError {
            #expect(error == .installationConflict)
        }
    }

    // MARK: - Revocation

    @Test("Revoke sends the gateway's full RevokeInstallationRequest shape")
    func revokeSuccess() async throws {
        let transport = ScriptedTransport(responses: [
            (Data(#"{"status":"revoked"}"#.utf8), 200),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        try await client.revokeInstallation(
            GatewayRevokeRequest(
                challengeID: "ch-9",
                challenge: "nonce-9",
                installationHandle: "handle-to-revoke",
                endpointEpoch: 1,
                newEndpointEpoch: 2,
                assertion: "base64assert"
            ),
            signer: signer()
        )

        let sent = transport.requests[0]
        #expect(sent.url.path.hasSuffix("/v1/installations/revoke"))
        let bodyJSON = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        #expect(bodyJSON?["v"] as? Int == 1)
        #expect(bodyJSON?["challenge_id"] as? String == "ch-9")
        #expect(bodyJSON?["challenge"] as? String == "nonce-9")
        #expect(bodyJSON?["installation_handle"] as? String == "handle-to-revoke")
        #expect(bodyJSON?["endpoint_epoch"] as? Int == 1)
        #expect(bodyJSON?["new_endpoint_epoch"] as? Int == 2)
        #expect(bodyJSON?["assertion"] as? String == "base64assert")
        #expect(bodyJSON?.count == 7)
    }

    @Test("Revoke surfaces a 404 as httpStatus with the gateway's error code")
    func revokeNotAuthorized() async throws {
        let transport = ScriptedTransport(responses: [
            (Data(#"{"error":"not_authorized"}"#.utf8), 404),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        do {
            try await client.revokeInstallation(
                GatewayRevokeRequest(
                    challengeID: "ch-9",
                    challenge: "nonce-9",
                    installationHandle: "gone",
                    endpointEpoch: 1,
                    newEndpointEpoch: 2,
                    assertion: "base64assert"
                ),
                signer: signer()
            )
            Issue.record("Expected httpStatus error")
        } catch let error as GatewayError {
            #expect(error == .httpStatus(404, "not_authorized"))
        }
    }

    // MARK: - Delegation

    @Test("Delegate decodes a well-formed response")
    func delegateSuccess() async throws {
        let responseJSON = #"{"endpoint_grant":"grant-token-xyz"}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 201),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let request = GatewayDelegationRequest(
            challengeID: "ch-456",
            challenge: "nonce-def",
            installationHandle: "handle-456",
            endpointEpoch: 1,
            generation: 1,
            relayPubkey: "aabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccddaabbccdd",
            notBefore: 1_700_000_000,
            expiresAt: 1_700_086_400,
            assertion: "base64assertion"
        )
        let response = try await client.delegate(request, signer: signer())

        #expect(response.endpointGrant == "grant-token-xyz")

        let sent = transport.requests[0]
        #expect(sent.url.path.hasSuffix("/v1/delegations"))
        let bodyJSON = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        #expect(bodyJSON?["v"] as? Int == 1)
        #expect(bodyJSON?["installation_handle"] as? String == "handle-456")
        #expect(bodyJSON?["challenge_id"] as? String == "ch-456")
        #expect(bodyJSON?["challenge"] as? String == "nonce-def")
        #expect(bodyJSON?["endpoint_epoch"] as? Int == 1)
        #expect(bodyJSON?["generation"] as? Int == 1)
        #expect(bodyJSON?["not_before"] as? Int == 1_700_000_000)
        #expect(bodyJSON?["expires_at"] as? Int == 1_700_086_400)
        #expect(bodyJSON?["assertion"] as? String == "base64assertion")
        // Must not send the old keys.
        #expect(bodyJSON?["installation_id"] == nil)
        #expect(bodyJSON?["relay_url"] == nil)
    }
}

// MARK: - Test double

/// A scripted HTTP transport that returns canned responses in order.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    struct Request {
        let url: URL
        let body: Data
        let headers: [String: String]
    }

    private(set) var requests: [Request] = []
    private var responses: [(Data, Int)]
    private var index = 0
    private let shouldThrow: Bool
    /// Runs synchronously as each request leaves, before any response, so a
    /// test can observe state at that instant (what is on disk, for example).
    var onRequest: ((Request) -> Void)?

    init(responses: [(Data, Int)], shouldThrow: Bool = false) {
        self.responses = responses
        self.shouldThrow = shouldThrow
    }

    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        let request = Request(url: url, body: body, headers: headers)
        requests.append(request)
        onRequest?(request)
        if shouldThrow {
            throw TransportError.requestFailed("scripted failure")
        }
        guard index < responses.count else {
            throw TransportError.requestFailed("no more scripted responses")
        }
        let response = responses[index]
        index += 1
        return response
    }
}
