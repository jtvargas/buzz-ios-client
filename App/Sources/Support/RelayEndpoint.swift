import Foundation

/// The relay endpoint the client talks to: a websocket URL for the live socket
/// and the derived HTTP `/query` URL the NIP-CW window client pages against.
///
/// The websocket URL is owner-chosen (prefilled, editable in the identity gate)
/// and persisted in `UserDefaults`; it is not a secret, so `UserDefaults` is the
/// right home. The key never touches this — it lives only in the Keychain.
enum RelayEndpoint {
    private static let storageKey = "relay.websocketURL"

    /// The persisted websocket URL string, empty until this device has been pointed at a
    /// relay.
    ///
    /// **Nothing is prefilled, deliberately.** A relay address belongs to whoever runs the
    /// relay, and the constant that used to sit here named one particular person's tailnet
    /// host — which every fresh install then showed on its first screen, in the relay row and
    /// in the community card above it, as though it were the client's own home. The two
    /// routes a reader is most likely to take carry their relay with them anyway: a desktop
    /// pairing QR supplies it, and so does an invite link.
    ///
    /// An empty value is a *state*, not a failure. ``OnboardingView`` opens the relay editor
    /// whenever the address is not usable, so an empty default lands the reader in an open
    /// field rather than behind a collapsed one.
    static var storedURLString: String {
        get { UserDefaults.standard.string(forKey: storageKey) ?? "" }
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
