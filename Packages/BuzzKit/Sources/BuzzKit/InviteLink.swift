import Foundation

/// An invitation to a community: which relay, which code, and — when the invite arrived
/// through the relay's own web page — proof that its terms were already accepted.
///
/// # The two forms, and why both
///
/// A Buzz invite is minted as `https://<relay-host>/invite/<code>`, which is a real page on
/// the relay: it fetches the join policy, shows the terms, and hands the reader to their
/// installed app as `buzz://join?relay=…&code=…&policy_receipt=…`
/// (`buzz/web/src/features/invite/ui/InvitePage.tsx:107-117`). So the same invitation
/// reaches this app two ways, and they differ in exactly one thing — whether the terms have
/// already been agreed to somewhere else. The `https` form is the link a person is given;
/// the `buzz` form is a handoff that has done the policy step for you.
///
/// Hive accepts both, and treats a missing receipt as "the terms have not been accepted
/// yet" rather than as a broken link — it can run that step itself
/// (§ ``InviteClient/acceptPolicy(code:policyVersion:ageConfirmed:)``). The Flutter client
/// only accepts a receipt that arrives in the link and asks the reader to reopen it
/// otherwise (`invite_join_provider.dart:276-278`); Desktop only runs the step itself. Doing
/// both is what makes a link pasted straight into this app work without a detour through
/// Safari.
public struct InviteLink: Equatable, Sendable {
    /// The relay to join, normalised to the websocket scheme the engine connects on.
    public let relayURLString: String
    /// The invite code, redeemed at `POST /api/invites/claim`.
    public let code: String
    /// Proof that the relay's current join policy was accepted for this exact code, when
    /// the link carried one. `nil` means the accepting still has to happen.
    public let policyReceipt: String?

    public init(relayURLString: String, code: String, policyReceipt: String? = nil) {
        self.relayURLString = relayURLString
        self.code = code
        self.policyReceipt = policyReceipt
    }

    /// The relay host, as it should be shown to someone deciding whether to join.
    ///
    /// The host *is* the identity of a community — there is no relay-signed name to check
    /// it against — so this is the one string a reader has to be able to read before
    /// agreeing to anything. Includes the port when the URL names one, because
    /// `relay.example:7777` and `relay.example` are different destinations.
    public var host: String {
        guard let url = URL(string: relayURLString), let host = url.host() else {
            return relayURLString
        }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    // MARK: - Parsing

    /// Reads an invite out of a link, or `nil` if the text is not one.
    ///
    /// Accepted, mirroring the Flutter client's parser (`deep_link.dart:151-217`) so a link
    /// that works on one phone works on the other:
    ///
    /// - `https://<host>/invite/<code>` → `wss://<host>`
    /// - `http://<host>/invite/<code>` → `ws://<host>`
    /// - `buzz://join?relay=<ws(s) URL>&code=<code>[&policy_receipt=<receipt>]`
    ///
    /// Everything else is refused, including credentials, fragments, and any path that is
    /// not exactly one non-empty code segment under `/invite`. A link is untrusted input
    /// that ends in this device authenticating to whatever host it names, so the parse is a
    /// whitelist: anything not recognised is not "probably fine", it is not an invite.
    ///
    /// - Parameter allowInsecureLocalRelay: whether a plaintext relay is acceptable. Debug
    ///   builds pass `true` so a local relay can be developed against; a shipping build
    ///   requires TLS and refuses private addresses outright (§ ``isAcceptableRelay(_:allowingInsecureLocal:)``).
    public static func parse(
        _ text: String,
        allowInsecureLocalRelay: Bool = defaultAllowsInsecureLocalRelay
    ) -> InviteLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        // A fragment or embedded credentials on the outer link are refused before the shape
        // is even considered: neither belongs on an invite, and both are how a host reads
        // as one thing and resolves as another.
        guard components.fragment == nil, components.user == nil, components.password == nil
        else { return nil }

        switch scheme {
        case "buzz":
            return parseHandoff(components, allowInsecureLocalRelay: allowInsecureLocalRelay)
        case "https", "http":
            return parseWebLink(components, scheme: scheme, allowInsecureLocalRelay: allowInsecureLocalRelay)
        default:
            return nil
        }
    }

    /// `buzz://join?relay=…&code=…` — the relay's web page handing off to the installed app.
    private static func parseHandoff(
        _ components: URLComponents,
        allowInsecureLocalRelay: Bool
    ) -> InviteLink? {
        // A custom scheme puts the authority in `host`, so the "join" in `buzz://join` is
        // the host and not a path component.
        guard components.host == "join" else { return nil }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        guard let relay = query["relay"], let code = query["code"],
              !relay.isEmpty, !code.isEmpty,
              let relayURLString = normalisedRelay(relay, allowingInsecureLocal: allowInsecureLocalRelay)
        else { return nil }
        let receipt = query["policy_receipt"]
        return InviteLink(
            relayURLString: relayURLString,
            code: code,
            policyReceipt: (receipt?.isEmpty ?? true) ? nil : receipt
        )
    }

    /// `https://<host>/invite/<code>` — the canonical shareable link.
    private static func parseWebLink(
        _ components: URLComponents,
        scheme: String,
        allowInsecureLocalRelay: Bool
    ) -> InviteLink? {
        let segments = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard segments.count == 2, segments[0] == "invite", !segments[1].isEmpty else { return nil }
        guard let host = components.host, !host.isEmpty else { return nil }
        let relayScheme = scheme == "https" ? "wss" : "ws"
        let port = components.port.map { ":\($0)" } ?? ""
        guard let relayURLString = normalisedRelay(
            "\(relayScheme)://\(host)\(port)",
            allowingInsecureLocal: allowInsecureLocalRelay
        ) else { return nil }
        // `URLComponents.path` is already percent-decoded, so the code is the segment as
        // written.
        return InviteLink(relayURLString: relayURLString, code: String(segments[1]))
    }

    // MARK: - Which relays a link may name

    /// Whether a shipping build should accept a plaintext local relay. Debug builds do, so
    /// a relay running on the development machine is reachable; a shipping build does not.
    public static var defaultAllowsInsecureLocalRelay: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The relay origin a link may be reduced to, or `nil` if this app will not connect
    /// there on a stranger's say-so.
    ///
    /// A pasted link ends in this device opening an authenticated socket to whatever host
    /// it names, so the rules are the Flutter client's, for the same reasons
    /// (`relay_validation.dart:10-67`): a websocket origin and nothing else — no path,
    /// query, fragment or credentials — TLS in a shipping build, and no IP literal that
    /// names this device or the network it is sitting on. The last one is what stops an
    /// invite link from being a way to make the phone talk to a printer.
    ///
    /// Hostnames are allowed through: refusing one that *resolves* to a private address
    /// needs pinning at connect time, which is a different layer's job. This is the same
    /// line Flutter draws.
    static func normalisedRelay(_ raw: String, allowingInsecureLocal: Bool) -> String? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil, components.query == nil,
              components.path.isEmpty || components.path == "/"
        else { return nil }

        let isLocalhost = host == "localhost" || host.hasSuffix(".localhost")
        if scheme != "wss", !(allowingInsecureLocal && isLocalhost) { return nil }
        if isLocalhost {
            guard allowingInsecureLocal else { return nil }
            return origin(scheme: scheme, host: host, port: components.port)
        }

        if let literal = IPv4Literal(host) {
            guard literal.isPublic else { return nil }
        } else if host.contains(":") || host.hasPrefix("[") {
            // An IPv6 literal. Classifying the special-purpose registry by hand is how the
            // Flutter port grew a hundred lines; refusing the whole form costs nothing here,
            // because a relay minting invites is reached by name.
            return nil
        } else if looksNumeric(host) {
            // A single integer, a hex form, or a dotted form with too few parts — legacy
            // spellings of an IPv4 address that different resolvers read differently.
            // Rejected rather than guessed at.
            return nil
        }
        return origin(scheme: scheme, host: host, port: components.port)
    }

    private static func origin(scheme: String, host: String, port: Int?) -> String {
        port.map { "\(scheme)://\(host):\($0)" } ?? "\(scheme)://\(host)"
    }

    /// Whether a host is written as a number in some form, and so is an address rather than
    /// a name — including the ambiguous spellings ``IPv4Literal`` refuses to read.
    private static func looksNumeric(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && (part.allSatisfy(\.isNumber) || isHexLiteral(part))
        }
    }

    private static func isHexLiteral(_ part: Substring) -> Bool {
        guard part.count > 2, part.hasPrefix("0x") || part.hasPrefix("0X") else { return false }
        return part.dropFirst(2).allSatisfy(\.isHexDigit)
    }
}

/// A dotted-decimal IPv4 address, read strictly, and what it is reachable from.
struct IPv4Literal {
    let octets: [UInt8]

    /// Reads canonical dotted-decimal only: four parts, each a plain decimal 0–255 with no
    /// leading zero. Every other spelling of an address — `0x7f.1`, `2130706433`, `010.1.1.1`
    /// — returns `nil`, because they are read differently by different resolvers and a
    /// classification made on one reading does not bind the other.
    init?(_ host: String) {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var values: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return nil }
            guard part.count == 1 || !part.hasPrefix("0") else { return nil }
            guard let value = UInt8(part) else { return nil }
            values.append(value)
        }
        octets = values
    }

    /// Whether this address is on the public internet rather than on this device, this
    /// network, or a reserved range. The list is the Flutter client's
    /// (`relay_validation.dart:145-164`).
    var isPublic: Bool {
        let (first, second, third) = (octets[0], octets[1], octets[2])
        let nonPublic =
            first == 0 // this network
                || first == 10 // private
                || first == 127 // loopback
                || (first == 100 && (64 ... 127).contains(second)) // carrier NAT, incl. Tailscale
                || (first == 169 && second == 254) // link-local
                || (first == 172 && (16 ... 31).contains(second)) // private
                || (first == 192 && second == 0 && (third == 0 || third == 2)) // IETF / documentation
                || (first == 192 && second == 168) // private
                || (first == 198 && (second == 18 || second == 19)) // benchmarking
                || (first == 198 && second == 51 && third == 100) // documentation
                || (first == 203 && second == 0 && third == 113) // documentation
                || first >= 224 // multicast and reserved
        return !nonPublic
    }
}
