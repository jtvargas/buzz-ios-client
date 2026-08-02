@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// What this client puts on the wire when it redeems an invitation.
///
/// # Why this is asserted rather than tried
///
/// Same reason as ``MediaUploadTests``: every field here is a contract with a relay this
/// test cannot reach, and getting one wrong does not fail loudly — it comes back as a bare
/// 403 with nothing naming which of the URL, the signature, the payload hash or the JSON
/// key was the problem. A live claim also cannot be repeated: joining is idempotent but
/// *minting* an invite is not, so there is no way to run this against a real relay twice.
/// So the request is taken apart here.
@Suite("Invite claiming")
struct InviteClientTests {
    /// One request as it went out.
    struct Recorded {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data?
    }

    /// Records what it was asked for and answers from a script.
    actor ScriptedTransport: InviteTransport {
        private(set) var requests: [Recorded] = []
        private var answers: [(Data, Int)]
        private let failure: TransportError?

        init(answers: [(Data, Int)] = [], failure: TransportError? = nil) {
            self.answers = answers
            self.failure = failure
        }

        func get(from url: URL, headers: [String: String]) async throws -> (Data, Int) {
            try await answer(method: "GET", url: url, headers: headers, body: nil)
        }

        func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
            try await answer(method: "POST", url: url, headers: headers, body: body)
        }

        private func answer(
            method: String,
            url: URL,
            headers: [String: String],
            body: Data?
        ) async throws -> (Data, Int) {
            requests.append(Recorded(method: method, url: url, headers: headers, body: body))
            if let failure { throw failure }
            return answers.isEmpty ? (Data(), 500) : answers.removeFirst()
        }
    }

    static func client(
        _ transport: ScriptedTransport,
        relay: String = "wss://relay.example"
    ) throws -> InviteClient {
        try #require(InviteClient(relayURLString: relay, transport: transport))
    }

    static func json(_ text: String) -> Data { Data(text.utf8) }

    /// Unwraps the `Nostr <base64(event)>` header back into the event it carries. Done here
    /// rather than through `NIP98`'s own decoder, which is internal to `NostrCore`.
    static func event(inHeader header: String) -> NostrEvent? {
        guard header.hasPrefix("Nostr ") else { return nil }
        guard let json = Data(base64Encoded: String(header.dropFirst("Nostr ".count))) else {
            return nil
        }
        return try? JSONDecoder().decode(NostrEvent.self, from: json)
    }

    // MARK: - The endpoint a relay actually serves

    /// The relay verifies the NIP-98 `u` tag against `{scheme}://{host}{path}`, with the
    /// host already stripped of a default port. Every part of that string is asserted,
    /// because a mismatch in any of them is one 403 with no explanation.
    @Test(
        "the HTTP base is the websocket URL with the scheme swapped and a default port dropped",
        arguments: [
            ("wss://relay.example", "https://relay.example"),
            ("wss://relay.example:443", "https://relay.example"),
            ("wss://relay.example:7777", "https://relay.example:7777"),
            ("ws://localhost:3004", "http://localhost:3004"),
            ("ws://localhost:80", "http://localhost"),
            ("wss://relay.example/", "https://relay.example"),
        ]
    )
    func httpBase(_ relay: String, _ expected: String) throws {
        let base = try #require(InviteClient.httpBase(forRelay: relay))
        #expect(base.absoluteString == expected)
    }

    @Test("a relay URL that is not a websocket URL has no invite endpoint")
    func rejectsNonWebsocketRelay() async {
        let transport = ScriptedTransport()
        #expect(InviteClient(relayURLString: "https://relay.example", transport: transport) == nil)
        #expect(InviteClient(relayURLString: "nonsense", transport: transport) == nil)
    }

    // MARK: - The claim

    @Test("a claim is a NIP-98 signed POST covering its own body")
    func claimRequestShape() async throws {
        let transport = ScriptedTransport(answers: [(
            Self.json(#"{"status":"joined","community_id":"c-1","host":"relay.example","role":"member"}"#),
            200
        )])
        let signer = try InMemorySigner()
        let claim = try await Self.client(transport)
            .claim(code: "v2.abc", policyReceipt: "r.mac", signer: signer)

        #expect(claim.wasAlreadyMember == false)
        #expect(claim.communityID == "c-1")
        #expect(claim.host == "relay.example")
        #expect(claim.role == "member")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://relay.example/api/invites/claim")
        #expect(request.headers["Content-Type"] == "application/json")

        // The relay refuses a signed POST whose body is not covered by a `payload` tag, and
        // verifies the tag against the bytes it received — so the header has to have been
        // built over the body that was actually sent, not over an equivalent one.
        let body = try #require(request.body)
        let header = try #require(request.headers["Authorization"])
        #expect(NIP98.validate(header: header, url: request.url, method: "POST", body: body))

        // The key that signed the authorisation is the key being admitted. A claim signed
        // by anyone else admits *them*, and this phone then opens the community
        // authenticated as someone who is not a member.
        let event = try #require(Self.event(inHeader: header))
        #expect(event.kind == EventKind.httpAuthentication)
        #expect(event.pubkey == (try await signer.publicKey().hex))

        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["code"] as? String == "v2.abc")
        #expect(sent["policy_receipt"] as? String == "r.mac")
    }

    /// `already_member` is a success. The claim route is idempotent by design, and a reader
    /// who taps a link twice — or who joined on another device with the same key — has to
    /// land in the community rather than on an error.
    @Test("claiming again reports membership rather than failing")
    func idempotentClaim() async throws {
        let transport = ScriptedTransport(answers: [(
            Self.json(#"{"status":"already_member","community_id":"c-1","host":"h","role":"member"}"#),
            200
        )])
        let claim = try await Self.client(transport)
            .claim(code: "abc", policyReceipt: nil, signer: try InMemorySigner())
        #expect(claim.wasAlreadyMember)
    }

    /// A claim with no receipt must omit the key entirely rather than send `null` — the
    /// relay's `Option<String>` reads both the same way, but sending the key is how a
    /// future stricter parser would start refusing every unpolicied join.
    @Test("no receipt sends no receipt field")
    func omitsAbsentReceipt() async throws {
        let transport = ScriptedTransport(answers: [(
            Self.json(#"{"status":"joined","community_id":"c","host":"h","role":"member"}"#),
            200
        )])
        _ = try await Self.client(transport)
            .claim(code: "abc", policyReceipt: nil, signer: try InMemorySigner())
        let body = try #require(await transport.requests.first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["code"] as? String == "abc")
        #expect(sent["policy_receipt"] == nil)
    }

    // MARK: - Reading the relay's refusals

    /// Each of these is a different thing for the reader to do, which is why they are read
    /// out of the body rather than collapsed into the status they all share.
    @Test(
        "the relay's named refusals become the reason a reader can act on",
        arguments: [
            (#"{"error":"invite_expired"}"#, 403, InviteError.expired),
            (#"{"error":"invite_exhausted"}"#, 403, InviteError.exhausted),
            (#"{"error":"invite_invalid"}"#, 403, InviteError.invalidCode),
            (#"{"error":"join_policy_required"}"#, 403, InviteError.policyRequired),
            (#"{"error":"join_policy_not_accepted"}"#, 400, InviteError.policyNotAccepted),
            (#"{"error":"join_policy_not_configured"}"#, 404, InviteError.noPolicyConfigured),
            // Rate limiting is named by its status, not by an error string.
            (#"{"error":"too many invite claim attempts, slow down"}"#, 429, InviteError.rateLimited),
            // An unnamed failure keeps its status rather than becoming a generic error: a
            // 500 and a 403 are not the same situation.
            ("", 500, InviteError.httpStatus(500)),
        ]
    )
    func refusals(_ body: String, _ status: Int, _ expected: InviteError) async throws {
        let transport = ScriptedTransport(answers: [(Self.json(body), status)])
        await #expect(throws: expected) {
            try await Self.client(transport)
                .claim(code: "abc", policyReceipt: nil, signer: try InMemorySigner())
        }
    }

    @Test("a relay that cannot be reached is not a relay that refused")
    func transportFailure() async throws {
        let transport = ScriptedTransport(failure: .requestFailed("offline"))
        await #expect(throws: InviteError.unreachable("requestFailed(\"offline\")")) {
            try await Self.client(transport)
                .claim(code: "abc", policyReceipt: nil, signer: try InMemorySigner())
        }
    }

    @Test("an answer that is not the documented JSON is unreadable, not a success")
    func unreadableClaim() async throws {
        let transport = ScriptedTransport(answers: [(Self.json(#"{"ok":true}"#), 200)])
        await #expect(throws: InviteError.unreadableResponse) {
            try await Self.client(transport)
                .claim(code: "abc", policyReceipt: nil, signer: try InMemorySigner())
        }
    }

    // MARK: - The policy

    @Test("a configured policy is read whole")
    func readsPolicy() async throws {
        let transport = ScriptedTransport(answers: [(
            Self.json(#"""
            {"policy":{"terms_markdown":"# Terms","privacy_markdown":"# Privacy",
             "age_attestation_required":true,"version":"v1"}}
            """#),
            200
        )])
        let policy = try #require(try await Self.client(transport).joinPolicy())
        #expect(policy.termsMarkdown == "# Terms")
        #expect(policy.privacyMarkdown == "# Privacy")
        #expect(policy.ageAttestationRequired)
        #expect(policy.version == "v1")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.absoluteString == "https://relay.example/api/join-policy")
        // Unauthenticated by contract: the endpoint is what a client reads *before* it has
        // an identity for this relay.
        #expect(request.headers["Authorization"] == nil)
    }

    /// Two different relays say "nothing to accept" two different ways, and a client that
    /// treated either as an error would refuse to join a relay that would have let it in.
    @Test(
        "a relay with no policy answers nothing, however it says so",
        arguments: [("{}", 200), (#"{"policy":null}"#, 200), (#"{"error":"not found"}"#, 404)]
    )
    func noPolicy(_ body: String, _ status: Int) async throws {
        let transport = ScriptedTransport(answers: [(Self.json(body), status)])
        #expect(try await Self.client(transport).joinPolicy() == nil)
    }

    @Test("accepting a policy is an unauthenticated exchange for a receipt")
    func acceptPolicyRequestShape() async throws {
        let transport = ScriptedTransport(answers: [(Self.json(#"{"receipt":"r.mac"}"#), 200)])
        let receipt = try await Self.client(transport)
            .acceptPolicy(code: "v2.abc", policyVersion: "v1", ageConfirmed: true)
        #expect(receipt == "r.mac")

        let request = try #require(await transport.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://relay.example/api/invites/accept-policy")
        #expect(request.headers["Authorization"] == nil)

        let body = try #require(request.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["code"] as? String == "v2.abc")
        #expect(sent["policy_version"] as? String == "v1")
        #expect(sent["age_confirmed"] as? Bool == true)
    }

    /// The attestation is the reader's to make. A client that sent `true` because the relay
    /// asked for `true` would be making a legal assertion on their behalf, so the value is
    /// passed through and the relay's refusal is the answer.
    @Test("an attestation that was not made is refused by the relay, not filled in")
    func ageAttestationIsNotAssumed() async throws {
        let transport = ScriptedTransport(answers: [
            (Self.json(#"{"error":"join_policy_not_accepted"}"#), 400),
        ])
        await #expect(throws: InviteError.policyNotAccepted) {
            try await Self.client(transport)
                .acceptPolicy(code: "abc", policyVersion: "v1", ageConfirmed: false)
        }
        let body = try #require(await transport.requests.first?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["age_confirmed"] as? Bool == false)
    }
}
