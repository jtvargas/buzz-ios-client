import Foundation
import NostrCore

/// A source of `Authorization` header values for reading the relay's media.
///
/// Behind a protocol so the image pipeline depends on the intent rather than on a
/// signer: a fixture or a UI test supplies `nil` and fetches media unauthenticated,
/// which is what every surface did before this existed.
public protocol MediaReadAuthorizing: Sendable {
    /// The header to send when fetching `url`, or `nil` when there is nothing to send
    /// — the URL is not this relay's media, or no grant could be minted.
    func authorization(for url: URL) async -> String?
}

/// Mints and reuses the signed grant a relay may require before it will serve a blob.
///
/// # Why a client that never needed one now does
///
/// `GET /media/<hash>.<ext>` is gated by the relay's own `require_media_get_auth`
/// (`crates/buzz-relay/src/api/media.rs`, `authenticate_media_read`). Deployments that
/// leave it off serve blobs to anyone, which is every relay this app had been pointed at
/// — so fetching a picture with no headers at all worked, and looked like the whole
/// contract. Against a deployment that turns it on, every attachment and every avatar
/// comes back `401` before the relay so much as looks for the file, and the app has no
/// way to tell that from a picture that is not there.
///
/// # The grant is per host, not per picture
///
/// The relay accepts a `server`-tagged authorisation *or* an `x`-tagged one
/// (`verify_blossom_get_auth`, `crates/buzz-media/src/auth.rs`), and documents the former
/// as granting reads for every blob on the host until it expires. So one signature covers
/// a whole screen of avatars rather than one each — which matters because signing reaches
/// the Keychain, and a conversation can ask for two dozen images in the same frame.
///
/// Held for ``lifetime`` and re-minted a minute before it lapses. The relay independently
/// requires the event to have been *created* within the hour whatever its `expiration`
/// says (rule 5), so a long-lived cached grant would start failing on a clock the client
/// cannot see; ten minutes sits well inside that and matches the upload twin.
///
/// # Anything that is not this relay gets nothing
///
/// A message can carry a picture from any host — another Blossom server, a link someone
/// pasted. Sending a signed grant there would hand a third party a signature bearing this
/// identity for the asking, so the host must match the relay this session is connected to
/// before anything is minted. Same rule Buzz Desktop applies before it proxies a URL.
public actor MediaReadAuthorizer: MediaReadAuthorizing {
    /// How long a minted grant is offered as valid.
    static let lifetime: TimeInterval = 600

    /// How long before expiry a fresh one is minted, so a fetch never leaves with a grant
    /// that lapses in flight.
    private static let renewalMargin: TimeInterval = 60

    private let relayAuthority: String?
    private let signer: any EventSigner
    private let now: @Sendable () -> Date

    /// The grant in hand, and the instant it stops being offered.
    private var cached: (header: String, expiresAt: Date)?

    /// The mint in flight, so a screen of images that all miss the cache in the same turn
    /// costs one signature rather than one each.
    private var minting: Task<String?, Never>?

    public init(
        baseURL: URL,
        signer: some EventSigner,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        relayAuthority = MediaUploadClient.serverAuthority(of: baseURL)
        self.signer = signer
        self.now = now
    }

    public func authorization(for url: URL) async -> String? {
        guard let relayAuthority,
              let authority = MediaUploadClient.serverAuthority(of: url),
              authority == relayAuthority
        else { return nil }

        if let cached, now() < cached.expiresAt { return cached.header }
        if let minting { return await minting.value }

        let task = Task<String?, Never> { [signer, now] in
            let issuedAt = now()
            let expiration = issuedAt.addingTimeInterval(Self.lifetime)
            let tags: [[String]] = [
                ["t", "get"],
                ["expiration", String(Int(expiration.timeIntervalSince1970))],
                ["server", relayAuthority],
            ]
            guard let event = try? await signer.sign(
                // Non-empty by requirement: the relay rejects a BUD-11 authorisation
                // whose content is blank.
                kind: MediaUploadClient.authorizationKind,
                content: "Get buzz-media",
                tags: tags,
                createdAt: issuedAt
            ) else { return nil }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard let encoded = try? encoder.encode(event) else { return nil }
            return "Nostr " + MediaUploadClient.base64URLUnpadded(encoded)
        }
        minting = task
        let header = await task.value
        minting = nil
        if let header {
            cached = (header, now().addingTimeInterval(Self.lifetime - Self.renewalMargin))
        }
        return header
    }
}
