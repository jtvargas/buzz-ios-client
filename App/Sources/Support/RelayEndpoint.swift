import Foundation

/// The relay endpoint the client talks to: a websocket URL for the live socket
/// and the derived HTTP `/query` URL the NIP-CW window client pages against.
///
/// The websocket URL is owner-chosen (prefilled, editable in the identity gate)
/// and persisted in `UserDefaults`; it is not a secret, so `UserDefaults` is the
/// right home. The key never touches this — it lives only in the Keychain.
enum RelayEndpoint {
    /// The prefilled relay: the owner's Pi over Tailscale, reached through the TLS
    /// endpoint Tailscale serves.
    ///
    /// It is `wss://…ts.net` and not the plain `ws://<tailnet-ip>:3004` it used to be,
    /// because that address no longer connects at all — measured 2026-07-26, the plaintext
    /// port refuses the WebSocket handshake outright (`NSURLErrorDomain -1011`), and NIP-42
    /// rejects it separately because the URL the client authenticates against has to match
    /// the one the relay advertises. A prefill that cannot connect is worse than no
    /// prefill: the URL is only editable during onboarding, so a fresh install that
    /// accepted the default had no way back out of it.
    static let defaultURLString = "wss://homelab.tail4bc643.ts.net"

    private static let storageKey = "relay.websocketURL"

    /// The persisted websocket URL string, defaulting to the prefill.
    static var storedURLString: String {
        get { UserDefaults.standard.string(forKey: storageKey) ?? defaultURLString }
        set { UserDefaults.standard.set(newValue, forKey: storageKey) }
    }

    /// Validates and normalises a websocket URL string, rejecting anything that is
    /// not a `ws`/`wss` URL with a host.
    static func websocketURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "ws" || scheme == "wss",
              url.host?.isEmpty == false
        else { return nil }
        return url
    }

    /// Normalises a relay URL that may arrive as an HTTP(S) API base into the
    /// `ws`/`wss` string the engine connects on, returning `nil` for anything that
    /// is neither a WebSocket nor an HTTP URL with a host.
    ///
    /// The NIP-AB pairing payload the desktop sends carries its *HTTP* API base as
    /// `relayUrl` (`relay_http_base_url` — `wss→https`, `ws→http`), not a socket
    /// URL. The engine needs the socket URL, so this inverts that mapping
    /// (`https→wss`, `http→ws`) while passing an already-`ws`/`wss` URL through
    /// untouched (the paste path).
    static func websocketURLString(fromAnyRelay raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased()
        else { return nil }
        switch scheme {
        case "ws", "wss": break
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        default: return nil
        }
        guard let candidate = components.string, websocketURL(from: candidate) != nil else { return nil }
        return candidate
    }

    /// The relay's HTTP root, derived from a websocket URL by swapping the scheme
    /// `ws → http` / `wss → https` and keeping the host, port and path.
    ///
    /// This is what the blob store hangs off — the upload client appends its own
    /// `upload` (and `media/upload`) path components, exactly as the mobile client
    /// does against the same relay. ``queryURL(for:)`` is the same base with
    /// `query` appended, and is left as its own function because a caller wanting
    /// one of them never wants the other.
    static func httpBaseURL(for websocketURL: URL) -> URL? {
        guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (websocketURL.scheme?.lowercased() == "ws") ? "http" : "https"
        return components.url
    }

    /// The HTTP `/query` endpoint derived from a websocket URL: the scheme is
    /// swapped `ws → http` / `wss → https` and a `query` path component appended —
    /// the Phase-1 integration pattern (`RelayIntegrationTests.swift:20-22,108`).
    static func queryURL(for websocketURL: URL) -> URL? {
        guard var components = URLComponents(url: websocketURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.scheme = (websocketURL.scheme?.lowercased() == "ws") ? "http" : "https"
        return components.url?.appendingPathComponent("query")
    }
}
