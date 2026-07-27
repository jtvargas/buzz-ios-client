import Foundation
import Observation

/// What this workspace is called — the name over the home screen.
///
/// # Where a name can honestly come from
///
/// There is no community record anywhere in the app. Channels have names, people have
/// names, the workspace has none: everything the client knows about "where am I signed in"
/// is one relay URL. So rather than invent a label, this asks the relay what it calls
/// itself — the NIP-11 information document it already serves at its HTTP origin, whose
/// `name` is the operator's own answer to that question ("Buzz Relay", on JT's).
///
/// The fetch is best-effort and never gates a frame. A name is cached the first time one
/// arrives, so the second launch draws it immediately and a relay that is unreachable — the
/// tailnet one, from off the tailnet — keeps showing the last name it gave rather than
/// flickering to a placeholder. With nothing cached, the relay's own host stands in.
enum CommunityIdentity {
    /// The `UserDefaults` key behind the cached name. Pinned by a test, like the star and
    /// expansion keys.
    static let storageKey = "relay.communityName"

    /// The last name the relay gave, if one ever has.
    static func cachedName(in defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: storageKey).flatMap(sanitised)
    }

    /// The name shown when the relay has never answered: its own host, first label only and
    /// capitalised — `homelab.tail4bc643.ts.net` reads as `Homelab`.
    ///
    /// A host is not a name, but it is *true*, which a hardcoded word would not be. The
    /// first label is the part an operator chose; the rest is the tailnet's.
    static func fallbackName(forRelay urlString: String) -> String {
        guard let host = RelayEndpoint.websocketURL(from: urlString)?.host(),
              let label = host.split(separator: ".").first,
              !label.isEmpty
        else { return defaultName }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    /// The last resort, when the stored relay URL is not one this app could even connect to.
    static let defaultName = "Buzz"

    /// The relay's NIP-11 information document URL: the same origin as the socket, over
    /// HTTP. `ws → http`, `wss → https`, and no path — the document is served at the root.
    static func informationURL(forRelay urlString: String) -> URL? {
        guard let websocket = RelayEndpoint.websocketURL(from: urlString),
              var components = URLComponents(url: websocket, resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = websocket.scheme?.lowercased() == "ws" ? "http" : "https"
        components.path = ""
        return components.url
    }

    /// The `name` out of a NIP-11 document, or `nil` when the document has none worth
    /// showing.
    ///
    /// Pure, so the parsing is tested against real relay bytes rather than over a socket.
    /// Everything else in the document is ignored: this asks one question.
    static func name(fromInformationDocument data: Data) -> String? {
        struct Document: Decodable { let name: String? }
        guard let document = try? JSONDecoder().decode(Document.self, from: data) else { return nil }
        return document.name.flatMap(sanitised)
    }

    /// A name fit to put in a title bar: trimmed, non-empty, and bounded.
    ///
    /// The cap is not cosmetic. The heading truncates by width already, but the string also
    /// becomes an accessibility label, and a relay is free to advertise a paragraph.
    static func sanitised(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maximumLength else { return trimmed }
        return String(trimmed.prefix(maximumLength)) + "\u{2026}"
    }

    private static let maximumLength = 60
}

/// The community's name, resolved for the home screen.
///
/// An object rather than a value because the name arrives after the first frame: it starts
/// at whatever is cached (or the relay's host), and moves once — if at all — when the relay
/// answers. Nothing else on the screen waits for it.
@MainActor
@Observable
final class CommunityModel {
    /// What the heading shows right now. Never empty.
    private(set) var name: String

    private let relayURLString: String
    private let defaults: UserDefaults
    /// How the document is fetched. Injected so the resolution can be driven in a test
    /// without a relay, and so a test can never reach the network.
    private let load: @Sendable (URL) async -> Data?

    init(
        relayURLString: String = RelayEndpoint.storedURLString,
        defaults: UserDefaults = .standard,
        load: @escaping @Sendable (URL) async -> Data? = CommunityModel.fetchInformationDocument
    ) {
        self.relayURLString = relayURLString
        self.defaults = defaults
        self.load = load
        name = CommunityIdentity.cachedName(in: defaults)
            ?? CommunityIdentity.fallbackName(forRelay: relayURLString)
    }

    /// Asks the relay what it is called, and remembers the answer.
    ///
    /// Failure is silent and leaves the current name in place: the document is a courtesy,
    /// not a dependency, and a relay that is asleep or off-tailnet must not turn the heading
    /// into an error.
    func run() async {
        guard let url = CommunityIdentity.informationURL(forRelay: relayURLString),
              let data = await load(url),
              let resolved = CommunityIdentity.name(fromInformationDocument: data)
        else { return }
        defaults.set(resolved, forKey: CommunityIdentity.storageKey)
        name = resolved
    }

    /// The production fetch: one short request for the NIP-11 document.
    ///
    /// `nonisolated` and `@Sendable` so it runs off the main actor. Ephemeral, because the
    /// cache that matters is the name in `UserDefaults` and a URL cache would only add a
    /// second, staler one.
    static let fetchInformationDocument: @Sendable (URL) async -> Data? = { url in
        var request = URLRequest(url: url)
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200 ..< 300).contains(http.statusCode)
        else { return nil }
        return data
    }
}
