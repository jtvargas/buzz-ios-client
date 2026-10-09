import Foundation

/// What the Notification Service Extension needs to know about one community in
/// order to act on a wake for it: where its relay is and which stored identity
/// speaks for the reader there.
///
/// Written by the app, read by the extension, one file per community in the App
/// Group (``PushSnapshotStore``). The extension never opens the app's database —
/// it has neither the memory for GRDB nor the right to a file the app may be
/// writing — so everything it needs at wake time has to be in here.
///
/// `version` guards the on-disk shape: the extension drops a snapshot it does not
/// understand rather than guessing at it, and an app that writes a new shape bumps
/// ``currentVersion`` and rewrites every snapshot at its next session start.
public struct PushCommunitySnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    /// The app's community id (`Community.ID.uuidString`), and the file's name.
    public let communityID: String
    public let name: String
    /// The `ws`/`wss` URL the live socket connects to.
    public let relayURL: URL
    /// The relay's HTTP root — `/query` and the blob store hang off it — derived
    /// from ``relayURL`` by the app so the extension carries no URL arithmetic.
    public let gatewayURL: URL
    /// The Keychain account the community's identity key is stored under
    /// (``IdentityKeychain``).
    public let keychainAccount: String
    public let updatedAt: Date

    // MARK: - Lease state (added JT-72, backward-compatible optionals)

    /// Whether a push lease is actively published for this community.
    /// `nil` decodes from pre-lease snapshots and is treated as `false`.
    public let leaseActive: Bool?
    /// When the current push lease expires, or `nil` when no lease is active.
    public let leaseExpiresAt: Date?
    /// The Nostr subscription filters in the current lease, JSON-encoded.
    /// `nil` when no lease is active.
    public let subscriptionFilters: String?

    public init(
        version: Int = currentVersion,
        communityID: String,
        name: String,
        relayURL: URL,
        gatewayURL: URL,
        keychainAccount: String,
        updatedAt: Date,
        leaseActive: Bool? = nil,
        leaseExpiresAt: Date? = nil,
        subscriptionFilters: String? = nil
    ) {
        self.version = version
        self.communityID = communityID
        self.name = name
        self.relayURL = relayURL
        self.gatewayURL = gatewayURL
        self.keychainAccount = keychainAccount
        self.updatedAt = updatedAt
        self.leaseActive = leaseActive
        self.leaseExpiresAt = leaseExpiresAt
        self.subscriptionFilters = subscriptionFilters
    }
}
