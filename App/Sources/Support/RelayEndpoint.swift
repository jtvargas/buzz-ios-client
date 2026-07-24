import Foundation

/// The relay endpoint the client talks to: a websocket URL for the live socket
/// and the derived HTTP `/query` URL the NIP-CW window client pages against.
///
/// The websocket URL is owner-chosen (prefilled, editable in the identity gate)
/// and persisted in `UserDefaults`; it is not a secret, so `UserDefaults` is the
/// right home. The key never touches this — it lives only in the Keychain.
enum RelayEndpoint {
    /// The prefilled relay for JT's Pi over Tailscale (spec §Identity gate).
    static let defaultURLString = "ws://100.111.202.55:3004"

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
