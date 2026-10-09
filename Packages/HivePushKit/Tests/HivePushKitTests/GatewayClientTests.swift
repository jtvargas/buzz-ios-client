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
        let responseJSON = #"{"challenge_id":"ch-123","challenge":"nonce-abc"}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 200),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let response = try await client.challenge(signer: signer())

        #expect(response.challengeID == "ch-123")
        #expect(response.challenge == "nonce-abc")

        // Verify request was to the right path.
        let request = transport.requests[0]
        #expect(request.url.path.hasSuffix("/v1/installations/challenges"))
        #expect(request.headers["Content-Type"] == "application/json")
        #expect(request.headers["Authorization"]?.hasPrefix("Nostr ") == true)
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
        let responseJSON = #"{"installation_id":"inst-456"}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 200),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let request = GatewayInstallRequest(
            deviceToken: "aabbccdd",
            attestation: "base64attest",
            keyID: "key-1",
            challengeID: "ch-123",
            appProfile: "buzz-ios-dogfood"
        )
        let response = try await client.install(request, signer: signer())

        #expect(response.installationID == "inst-456")

        // Verify the request body was JSON-encoded correctly.
        let sent = transport.requests[0]
        #expect(sent.url.path.hasSuffix("/v1/installations"))
        let bodyJSON = try JSONSerialization.jsonObject(with: sent.body) as? [String: Any]
        #expect(bodyJSON?["device_token"] as? String == "aabbccdd")
        #expect(bodyJSON?["key_id"] as? String == "key-1")
        #expect(bodyJSON?["app_profile"] as? String == "buzz-ios-dogfood")
    }

    // MARK: - Delegation

    @Test("Delegate decodes a well-formed response")
    func delegateSuccess() async throws {
        let responseJSON = #"{"delegation_id":"del-789"}"#
        let transport = ScriptedTransport(responses: [
            (Data(responseJSON.utf8), 200),
        ])
        let client = GatewayClient(baseURL: baseURL, transport: transport)
        let request = GatewayDelegationRequest(
            installationID: "inst-456",
            relayURL: "wss://relay.example",
            relayPubkey: "aabbccdd"
        )
        let response = try await client.delegate(request, signer: signer())

        #expect(response.delegationID == "del-789")
        let sent = transport.requests[0]
        #expect(sent.url.path.hasSuffix("/v1/delegations"))
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

    init(responses: [(Data, Int)], shouldThrow: Bool = false) {
        self.responses = responses
        self.shouldThrow = shouldThrow
    }

    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        requests.append(Request(url: url, body: body, headers: headers))
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
