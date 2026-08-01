import Foundation
import NostrCore

/// The HTTP verbs an invite is redeemed over.
///
/// Its own protocol rather than an addition to ``NostrCore/HTTPTransport``, for the reason
/// ``MediaUploadTransport`` gives: that protocol has four conformers, three of them test
/// doubles whose subjects never issue a `GET`. ``NostrCore/URLSessionHTTPTransport``
/// satisfies this one already.
public protocol InviteTransport: Sendable {
    func get(from url: URL, headers: [String: String]) async throws -> (Data, Int)
    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int)
}

extension URLSessionHTTPTransport: InviteTransport {}

/// What a relay requires of someone joining it, when it requires anything.
///
/// Served by `GET /api/join-policy`, which answers `{}` on a relay with no policy
/// configured — the common case, and the one every self-hosted relay is in.
public struct JoinPolicy: Equatable, Sendable {
    /// The terms of service, as Markdown the client renders. `nil` when the operator
    /// configured a policy without one.
    public let termsMarkdown: String?
    /// The privacy notice, as Markdown.
    public let privacyMarkdown: String?
    /// Whether the operator requires the joiner to assert a minimum age. The relay refuses
    /// to issue a receipt without it (`api/invites.rs:215-222`), so this is not advisory.
    public let ageAttestationRequired: Bool
    /// The revision being agreed to. A receipt is bound to it, and a claim carrying a
    /// receipt for a superseded revision is refused — so the version shown must be the
    /// version accepted.
    public let version: String

    public init(
        termsMarkdown: String?,
        privacyMarkdown: String?,
        ageAttestationRequired: Bool,
        version: String
    ) {
        self.termsMarkdown = termsMarkdown
        self.privacyMarkdown = privacyMarkdown
        self.ageAttestationRequired = ageAttestationRequired
        self.version = version
    }
}

/// The relay's answer to a claim: that this key is now a member, and of what.
public struct InviteClaim: Equatable, Sendable {
    /// Whether this claim admitted the key, or found it was already a member. Both are
    /// success — a claim is idempotent by design (`api/invites.rs:425-431`), which is what
    /// makes a retried claim safe where a retried channel *creation* is not.
    public let wasAlreadyMember: Bool
    /// The relay's own id for the community joined.
    public let communityID: String
    /// The host the relay answered as, which is the community's identity.
    public let host: String
    /// The role granted. `member` for every invite the client can mint.
    public let role: String
}

/// Why an invite could not be redeemed.
///
/// Each case is one thing the reader can do something about, which is why the relay's
/// error strings are read rather than shown: `invite_exhausted` means ask for another link,
/// `join_policy_required` means the terms step has to happen first, and a transport failure
/// means try again. Showing the wire string instead would tell a reader who cannot fix any
/// of it that something called `invite_exhausted` happened.
public enum InviteError: Error, Equatable {
    /// The code is not one this relay issued, or is malformed.
    case invalidCode
    /// The code was valid and has expired.
    case expired
    /// The code has been used as many times as it was minted for.
    case exhausted
    /// The relay has a join policy and the claim carried no acceptance of it — or carried
    /// one bound to a different code or a superseded revision.
    case policyRequired
    /// The relay refused to issue a receipt: the revision offered was not its current one,
    /// or an age attestation it requires was not made.
    case policyNotAccepted
    /// This relay has no join policy to accept, so there is no receipt to be had.
    case noPolicyConfigured
    /// Too many claims from this key in the last minute (`api/invites.rs:42`).
    case rateLimited
    /// The request never produced an HTTP response.
    case unreachable(String)
    /// The relay answered with a status this client has no reading for.
    case httpStatus(Int)
    /// The relay answered, and the answer was not the JSON this endpoint documents.
    case unreadableResponse
    /// The relay URL could not be turned into an HTTP endpoint.
    case invalidRelayURL
}

/// Redeems an invitation against the relay that minted it.
///
/// # The three calls, and which of them needs a key
///
/// 1. `GET /api/join-policy` — unauthenticated. What the relay asks of a joiner, if
///    anything.
/// 2. `POST /api/invites/accept-policy` — **also unauthenticated**, and deliberately so:
///    the handler takes no headers at all (`api/invites.rs:199-202`), because the acceptance
///    is bound to the *invite code*, not to an identity. The receipt it returns is an HMAC
///    over `(code, policy version)` that only this relay can mint or verify.
/// 3. `POST /api/invites/claim` — NIP-98 signed **by the key that will own this community**,
///    which is the whole mechanism: the signature is what proves control of the pubkey being
///    admitted, and it is why this client is handed a signer rather than reaching for the
///    app's current one. At the moment a claim is made there may be no current one — this
///    is how a phone joins its first community.
///
/// The claim route is exempt from the relay's membership gate on purpose ("the whole point
/// is that the caller is not a member yet" — `api/invites.rs:8-10`). Every *other* HTTP
/// route on a closed relay answers 403 until this one has succeeded, which is exactly the
/// wall a client without an invite flow runs into.
public struct InviteClient: Sendable {
    private let transport: any InviteTransport
    /// The relay's HTTP root: `https://<host>` for a `wss` relay, `http://<host>` for `ws`.
    private let baseURL: URL

    /// - Parameters:
    ///   - relayURLString: the relay's websocket URL, as an invite link carries it.
    ///   - transport: the HTTP seam; the production one is `URLSessionHTTPTransport`.
    public init?(relayURLString: String, transport: any InviteTransport) {
        guard let baseURL = Self.httpBase(forRelay: relayURLString) else { return nil }
        self.baseURL = baseURL
        self.transport = transport
    }

    /// The relay's HTTP root, derived from its websocket URL.
    ///
    /// The scheme swaps `wss → https` / `ws → http`, and a port that is the *default* for
    /// the resulting scheme is dropped. That last part is not cosmetic: the relay verifies
    /// the NIP-98 `u` tag against `{scheme}://{host}{path}` where the host has already had
    /// `:443`/`:80` stripped (`buzz-core/src/tenant.rs:121-138`), so a URL carrying an
    /// explicit `:443` signs for a string the relay will not match and the claim comes back
    /// 403 with nothing wrong with it.
    static func httpBase(forRelay relayURLString: String) -> URL? {
        guard var components = URLComponents(string: relayURLString.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              components.host?.isEmpty == false
        else { return nil }
        switch scheme {
        case "wss": components.scheme = "https"
        case "ws": components.scheme = "http"
        default: return nil
        }
        if components.port == (components.scheme == "https" ? 443 : 80) {
            components.port = nil
        }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    // MARK: - 1. What does this relay ask of me?

    /// The relay's join policy, or `nil` when it has none.
    ///
    /// Two answers mean the same thing and both are `nil`: a 200 whose body has no `policy`
    /// key (a relay running this code with nothing configured) and a 404 (a relay predating
    /// the endpoint). Desktop reads both the same way (`invites.ts:150`), and a client that
    /// treated the older relay as an error would refuse to join it at all.
    public func joinPolicy() async throws -> JoinPolicy? {
        let url = baseURL.appending(path: "api/join-policy")
        let (body, status) = try await send { try await transport.get(from: url, headers: [:]) }
        if status == 404 { return nil }
        guard (200 ... 299).contains(status) else { throw InviteError.httpStatus(status) }
        guard let envelope = try? JSONDecoder().decode(JoinPolicyEnvelope.self, from: body) else {
            throw InviteError.unreadableResponse
        }
        return envelope.policy.map {
            JoinPolicy(
                termsMarkdown: $0.termsMarkdown,
                privacyMarkdown: $0.privacyMarkdown,
                ageAttestationRequired: $0.ageAttestationRequired,
                version: $0.version
            )
        }
    }

    // MARK: - 2. I accept

    /// Exchanges an explicit acceptance for a receipt bound to this code and this revision.
    ///
    /// Unauthenticated, and it does not need to be authenticated: the receipt is worthless
    /// without the code it is bound to, and the code is what the claim already proves you
    /// were given.
    ///
    /// - Parameter ageConfirmed: pass only what the reader actually asserted. The relay
    ///   refuses the exchange when it requires an attestation and this is false, which is
    ///   the point — it is not a field the client may fill in for them.
    public func acceptPolicy(
        code: String,
        policyVersion: String,
        ageConfirmed: Bool
    ) async throws -> String {
        let url = baseURL.appending(path: "api/invites/accept-policy")
        let payload = try JSONEncoder().encode(
            AcceptPolicyRequest(code: code, policyVersion: policyVersion, ageConfirmed: ageConfirmed)
        )
        let (body, status) = try await send {
            try await transport.post(
                body: payload,
                to: url,
                headers: ["Content-Type": "application/json"]
            )
        }
        guard (200 ... 299).contains(status) else {
            throw Self.error(forStatus: status, body: body)
        }
        guard let receipt = try? JSONDecoder().decode(AcceptPolicyResponse.self, from: body).receipt,
              !receipt.isEmpty
        else { throw InviteError.unreadableResponse }
        return receipt
    }

    // MARK: - 3. Let me in

    /// Redeems the code, admitting `signer`'s pubkey to the community.
    ///
    /// - Parameter signer: the identity being admitted. This is the key the community will
    ///   be *signed with afterwards* — a claim made by one key and a community opened with
    ///   another leaves a phone authenticated as somebody who is not a member.
    public func claim(
        code: String,
        policyReceipt: String?,
        signer: some EventSigner
    ) async throws -> InviteClaim {
        let url = baseURL.appending(path: "api/invites/claim")
        let payload = try JSONEncoder().encode(
            ClaimRequest(code: code, policyReceipt: policyReceipt)
        )
        // The relay requires POST bodies to be covered by the NIP-98 `payload` tag
        // (`api/invites.rs:249-257`), which `NIP98` always writes — so the body has to be
        // final before the header is built, and it is the same bytes that get sent.
        let authorization = try await NIP98.authorizationHeader(
            url: url,
            method: "POST",
            body: payload,
            signer: signer
        )
        let (body, status) = try await send {
            try await transport.post(
                body: payload,
                to: url,
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": authorization,
                ]
            )
        }
        guard (200 ... 299).contains(status) else {
            throw Self.error(forStatus: status, body: body)
        }
        guard let response = try? JSONDecoder().decode(ClaimResponse.self, from: body) else {
            throw InviteError.unreadableResponse
        }
        return InviteClaim(
            wasAlreadyMember: response.status == "already_member",
            communityID: response.communityID,
            host: response.host,
            role: response.role
        )
    }

    // MARK: - Reading the relay's refusals

    /// Turns a refusal into the one thing the reader can do about it.
    ///
    /// The relay names its refusals in an `error` field and they are stable strings, so they
    /// are matched rather than displayed (`api/invites.rs:433-441`). A status with no
    /// recognised name falls back to the status itself rather than being reported as a
    /// generic failure — a 500 and a 403 are different situations.
    static func error(forStatus status: Int, body: Data) -> InviteError {
        let name = (try? JSONDecoder().decode(ErrorEnvelope.self, from: body))?.error
        switch name {
        case "invite_expired": return .expired
        case "invite_exhausted": return .exhausted
        case "invite_invalid": return .invalidCode
        case "join_policy_required": return .policyRequired
        case "join_policy_not_accepted": return .policyNotAccepted
        case "join_policy_not_configured": return .noPolicyConfigured
        default: break
        }
        if status == 429 { return .rateLimited }
        return .httpStatus(status)
    }

    /// Runs one round-trip, turning a transport failure into this taxonomy and letting a
    /// cancellation through untouched.
    private func send(
        _ body: () async throws -> (Data, Int)
    ) async throws -> (Data, Int) {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransportError {
            throw InviteError.unreachable(String(describing: error))
        }
    }
}

// MARK: - Wire shapes

private struct JoinPolicyEnvelope: Decodable {
    let policy: WirePolicy?
}

private struct WirePolicy: Decodable {
    let termsMarkdown: String?
    let privacyMarkdown: String?
    let ageAttestationRequired: Bool
    let version: String

    private enum CodingKeys: String, CodingKey {
        case termsMarkdown = "terms_markdown"
        case privacyMarkdown = "privacy_markdown"
        case ageAttestationRequired = "age_attestation_required"
        case version
    }
}

private struct AcceptPolicyRequest: Encodable {
    let code: String
    let policyVersion: String
    let ageConfirmed: Bool

    private enum CodingKeys: String, CodingKey {
        case code
        case policyVersion = "policy_version"
        case ageConfirmed = "age_confirmed"
    }
}

private struct AcceptPolicyResponse: Decodable {
    let receipt: String
}

private struct ClaimRequest: Encodable {
    let code: String
    let policyReceipt: String?

    private enum CodingKeys: String, CodingKey {
        case code
        case policyReceipt = "policy_receipt"
    }
}

private struct ClaimResponse: Decodable {
    let status: String
    let communityID: String
    let host: String
    let role: String

    private enum CodingKeys: String, CodingKey {
        case status
        case communityID = "community_id"
        case host
        case role
    }
}

private struct ErrorEnvelope: Decodable {
    let error: String?
}
