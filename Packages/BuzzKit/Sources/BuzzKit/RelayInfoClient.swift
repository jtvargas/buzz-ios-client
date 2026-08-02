import Foundation
import NostrCore

/// What a relay says about itself, before this device has any standing to ask it anything.
///
/// # Why this is worth fetching at all
///
/// The information document is served at the relay's own HTTP origin, **unauthenticated**,
/// and a Buzz relay answers it from a key it has never seen. That is the whole value: every
/// other route on a relay with `require_relay_membership` set answers `403` until an invite
/// has been redeemed, so this is the only thing a phone can learn about a community it is
/// deciding whether to join. Verified against a closed relay, which answers this and refuses
/// `/api/channels` in the same breath.
///
/// # What it can and cannot tell you
///
/// It **can** confirm that a real relay is reachable at that host over TLS, and that it is
/// running Buzz's own relay software (§ ``isBuzzRelay``).
///
/// It **cannot** name the community. `name` and `description` are the same hardcoded strings
/// on every Buzz deployment — `"Buzz Relay"` at `buzz/crates/buzz-relay/src/nip11.rs:154` —
/// and deliberately so: the document is unauthenticated, so a host-scoped fact in it would be
/// an oracle for enumerating the other communities on the same deployment. A build-time fence
/// at `nip11.rs:308-320` fails the build if anyone widens the inputs. So those two fields are
/// not read here at all, because the only thing a client could do with them is label every
/// community alike. § `CommunityIdentity` for what Hive shows instead — the same host-derived
/// name Buzz Desktop puts on the same relay.
///
/// The single exception, and the reason this type exists rather than a bare reachability
/// check: ``icon`` **is** host-scoped. It is the community's own workspace icon, set by its
/// owner and looked up per host (`nip11.rs:239-288`), and it is omitted entirely when unset.
public struct RelayInfo: Equatable, Sendable {
    /// The community's workspace icon, as the relay writes it — a `data:` URL on a hosted
    /// Buzz deployment, absent on a relay whose owner never set one. Read through
    /// ``communityIcon`` rather than directly.
    public let icon: String?
    /// The relay software's repository URL. A constant on Buzz (`nip11.rs:167`), which is
    /// what makes it usable as a check rather than as a description.
    public let software: String?

    public init(icon: String? = nil, software: String? = nil) {
        self.icon = icon
        self.software = software
    }

    /// The repository every Buzz relay names itself by.
    public static let buzzSoftware = "https://github.com/block/buzz"

    /// Whether this host is running Buzz rather than some other Nostr relay.
    ///
    /// The honest half of a "verified" claim. A plain Nostr relay answers this document too
    /// and has no invite API at all, so a client that treated any answer as a Buzz community
    /// would promise a join it cannot perform.
    public var isBuzzRelay: Bool { software == Self.buzzSoftware }

    /// The icon in a form something can draw, or `nil` when this community has none.
    public var communityIcon: RelayIcon? { icon.flatMap(RelayIcon.init(source:)) }
}

/// A community's workspace icon, in whichever of the two forms the relay served it.
///
/// Both are refusals-by-default. A `data:` URL is accepted only when it is base64 and
/// declares an image type, and only up to ``maximumInlineBytes`` — these are bytes from a
/// host nobody has agreed to trust yet, decoded before anyone has joined. A remote URL is
/// accepted only over `https`, because an icon fetched in the clear from an unjoined host is
/// a plaintext request this screen has no reason to make.
public enum RelayIcon: Equatable, Sendable {
    /// Bytes carried in the document itself, which is what a hosted Buzz relay serves.
    case inline(Data)
    /// An `https` URL to fetch.
    case remote(URL)

    /// The most an inline icon may decode to. A hosted community's is a few kilobytes; the
    /// bound exists because the document is served to anyone and this is the one field in it
    /// whose size the operator chooses.
    public static let maximumInlineBytes = 512 * 1024

    /// Reads the `icon` string a relay served, or `nil` if it is not something to draw.
    public init?(source: String) {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.lowercased().hasPrefix("data:") {
            guard let data = Self.inlineData(from: trimmed) else { return nil }
            self = .inline(data)
            return
        }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https" else {
            return nil
        }
        self = .remote(url)
    }

    /// Decodes `data:image/<type>;base64,<payload>`, and nothing else.
    ///
    /// The percent-encoded form of a data URL is refused rather than supported: the relay
    /// writes base64 (`nip11.rs`), no other Buzz client reads anything else, and every
    /// additional accepted spelling is another way for bytes to reach an image decoder.
    private static func inlineData(from source: String) -> Data? {
        guard let comma = source.firstIndex(of: ","), comma > source.startIndex else { return nil }
        let header = source[source.index(source.startIndex, offsetBy: 5) ..< comma].lowercased()
        let parameters = header.split(separator: ";", omittingEmptySubsequences: true)
        guard parameters.contains("base64"), parameters.first?.hasPrefix("image/") == true else {
            return nil
        }
        // The payload may be wrapped, and `Data(base64Encoded:)` refuses a string with
        // newlines in it unless told otherwise.
        let payload = String(source[source.index(after: comma)...])
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]),
              !data.isEmpty, data.count <= maximumInlineBytes
        else { return nil }
        return data
    }
}

/// Why a relay's information document could not be read.
public enum RelayInfoError: Error, Equatable {
    /// The request never produced an HTTP response.
    case unreachable(String)
    /// Something answered, and it was not a success.
    case httpStatus(Int)
    /// Something answered with a body this is not.
    case unreadableResponse
}

/// Reads a relay's information document.
///
/// Takes the same `ws`/`wss` relay URL the rest of the app identifies a community by, so a
/// caller that has normalised an address once does not have to normalise it differently here.
public struct RelayInfoClient: Sendable {
    private let transport: any InviteTransport
    private let origin: URL

    /// - Parameters:
    ///   - relayURLString: the relay's websocket URL.
    ///   - transport: the HTTP seam; the production one is `URLSessionHTTPTransport`.
    public init?(relayURLString: String, transport: any InviteTransport) {
        guard let origin = InviteClient.httpBase(forRelay: relayURLString) else { return nil }
        self.origin = origin
        self.transport = transport
    }

    /// Fetches the document from the relay's origin.
    ///
    /// `Accept: application/nostr+json` is what distinguishes this from a browser asking for
    /// the relay's web app at the same URL — a Buzz relay serves its SPA otherwise
    /// (`buzz/crates/buzz-relay/src/router.rs`), so without the header this reads HTML.
    public func fetch() async throws -> RelayInfo {
        let (body, status): (Data, Int)
        do {
            (body, status) = try await transport.get(
                from: origin,
                headers: ["Accept": "application/nostr+json"]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RelayInfoError.unreachable(String(describing: error))
        }
        guard (200 ... 299).contains(status) else { throw RelayInfoError.httpStatus(status) }
        guard let wire = try? JSONDecoder().decode(WireRelayInfo.self, from: body) else {
            throw RelayInfoError.unreadableResponse
        }
        return RelayInfo(icon: wire.icon, software: wire.software)
    }
}

// MARK: - Wire shape

/// Every field optional.
///
/// A relay that predates a field, or that is not Buzz at all, must still be readable — the
/// point of the fetch is to find out *what* answered, and a decode that fails on a missing
/// field would report a perfectly real relay as unreachable.
private struct WireRelayInfo: Decodable {
    let icon: String?
    let software: String?
}
