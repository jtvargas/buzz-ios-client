import Foundation

/// What this workspace is called — the name over the home screen.
///
/// # There is no community name on the server to ask for
///
/// This used to ask the relay, over NIP-11: the information document served at the relay's
/// own HTTP origin carries a `name`, and the operator's answer to "what is this" looked like
/// the one honest source. It is not one. Every Buzz relay returns the same hardcoded string
/// — `"Buzz Relay"`, at `buzz/crates/buzz-relay/src/nip11.rs:154` — on every deployment, and
/// does so *deliberately*: the document is served unauthenticated, so any host-scoped fact in
/// it would turn a NIP-11 read into an oracle for enumerating the other communities on the
/// same deployment. That is the static-input fence at `nip11.rs:308-320`, which fails the
/// build if anyone widens the inputs, and the one host-scoped field it does allow through is
/// the workspace icon. The pairing credential Hive imports cannot answer either: it is
/// exactly `{relayUrl, pubkey, nsec}` (`buzz/desktop/src-tauri/src/commands/pairing.rs:99`).
///
/// # So every Buzz client makes one up from the host, and this makes up the same one
///
/// comb reaches the same conclusion in its own words and derives from the subdomain
/// (`comb/Comb/Identity/CommunityRegistry.swift:14-32`); the Flutter mobile client derives
/// from the host (`Community.nameFromUrl`, `buzz/mobile/lib/shared/community/community.dart:74`);
/// and Buzz Desktop derives from the host and then lets the owner rename it
/// (`deriveCommunityName`, `buzz/desktop/src/features/communities/communityStorage.ts:130`).
/// The name is a client-local label, everywhere.
///
/// Hive copies **Desktop's** rule specifically, because a Hive install is paired to a
/// Desktop: the two screens are looking at the same relay, sitting on the same desk, and a
/// phone that called it one thing while the laptop beside it called it another would be
/// reporting a disagreement that does not exist. So the rule is copied character for
/// character, including where it is crude — an IP-address relay yields its first octet, and
/// `hive.example.ts.net` reads as the lowercase `relay` Desktop shows — because
/// agreeing with the screen next to it beats being cleverer on its own. Title-casing the
/// label was tried and removed for exactly that reason: it is a nicer heading and it is a
/// visible disagreement, which is the one thing this is here to avoid.
enum CommunityIdentity {
    /// The name over the home screen, for the relay this device is signed in to.
    ///
    /// A pure function of a string already in `UserDefaults`, so the heading has its name in
    /// the first body pass: there is nothing to fetch, nothing to cache, and no frame where
    /// the workspace is unnamed.
    static func name(forRelay urlString: String = RelayEndpoint.storedURLString) -> String {
        // The socket URL this app would actually connect on, which is the only relay it can
        // be signed in to. Anything else is not a relay, so there is nothing true to derive
        // from it — where Desktop rewrites `ws → http` before parsing because that is what
        // its URL parser wants, Foundation parses `wss://` directly and the rewrite would
        // only be ceremony.
        guard let host = RelayEndpoint.websocketURL(from: urlString)?.host() else {
            return defaultName
        }
        // Lowercased before anything is matched against it, because that is what Desktop
        // compares: WHATWG `URL.hostname` lowercases the host during parsing, Foundation's
        // `URL.host()` hands it back as typed. Without this, an owner who typed
        // `wss://Relay.example.ts.net` gets `Relay` on the phone and `relay` on the
        // laptop, and `ws://LOCALHOST:3004` misses the local-host set here while matching it
        // there. Hostnames are case-insensitive, so this loses nothing.
        return sanitised(derivedName(fromHost: host.lowercased())) ?? defaultName
    }

    /// What a relay URL this app could not parse is called. Desktop's word for the same
    /// case, not an invention of Hive's.
    static let defaultName = "Community"

    /// Desktop's rule, label for label. See the type comment for why it is copied rather
    /// than improved on.
    ///
    /// The two fixed answers are spelled as Desktop spells them — `Local Dev`, and
    /// `Buzz (staging)` with the lowercase word in brackets — because they are strings
    /// Desktop writes out rather than labels either client borrows from a host.
    private static func derivedName(fromHost host: String) -> String {
        if localHosts.contains(host) { return "Local Dev" }
        let labels = host.split(separator: ".")
        if labels.contains(where: { $0 == "stage" || $0 == "staging" }) { return "Buzz (staging)" }
        // A single-label host — `wss://myrelay` on a LAN with a search domain — has no
        // subdomain to take, so the host itself is the answer.
        guard labels.count >= 2 else { return host }
        // `relay.acme.com` names the machine before the community, so the label after it is
        // the one an operator chose.
        return String(labels[0] == "relay" ? labels[1] : labels[0])
    }

    /// The hosts that mean "this developer's own machine".
    ///
    /// `::1` is in here as well as Desktop's `[::1]` because the bracket form is a URL
    /// syntax rather than a host: JavaScript's `URL.hostname` keeps the brackets and
    /// Foundation's `URL.host()` strips them, so matching Desktop's literal alone would
    /// never fire on iOS. Verified against Foundation rather than assumed.
    private static let localHosts: Set<String> = [
        "localhost", "127.0.0.1", "[::1]", "::1", "0.0.0.0",
    ]

    /// A name fit to put in a title bar: trimmed, non-empty, and bounded.
    ///
    /// The only step Desktop has no counterpart for, and the one place a divergence is worth
    /// it: the heading truncates by width already, but this string also becomes an
    /// accessibility label, which VoiceOver reads in full. A DNS label may be 63 characters,
    /// so the bound is reachable without anybody being hostile. It bites above 60 characters
    /// and no host in practice comes near that, so the two clients still agree on every name
    /// either of them will really show.
    static func sanitised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumLength else { return trimmed }
        return String(trimmed.prefix(maximumLength)) + "\u{2026}"
    }

    private static let maximumLength = 60
}
