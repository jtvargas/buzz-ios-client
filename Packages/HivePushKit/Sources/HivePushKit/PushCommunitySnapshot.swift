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
    public static let currentVersion = 2

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
    public let leaseActive: Bool
    public let leaseExpiresAt: Date?
    /// NIP-44-decrypted subscriptions. JSON value storage keeps the snapshot
    /// Sendable without allowing reference-typed `Any` values across tasks.
    public var subscriptionFilters: [[String: Any]]? {
        filters?.map { $0.mapValues(\.foundationValue) }
    }

    private let filters: [[String: PushJSONValue]]?

    private enum CodingKeys: String, CodingKey {
        case version, communityID, name, relayURL, gatewayURL, keychainAccount, updatedAt
        case leaseActive, leaseExpiresAt
        case filters = "subscriptionFilters"
    }


    public init(
        version: Int = currentVersion,
        communityID: String,
        name: String,
        relayURL: URL,
        gatewayURL: URL,
        keychainAccount: String,
        updatedAt: Date,
        leaseActive: Bool = false,
        leaseExpiresAt: Date? = nil,
        subscriptionFilters: [[String: Any]]? = nil
    ) throws {
        self.version = version
        self.communityID = communityID
        self.name = name
        self.relayURL = relayURL
        self.gatewayURL = gatewayURL
        self.keychainAccount = keychainAccount
        self.updatedAt = updatedAt
        self.leaseActive = leaseActive
        self.leaseExpiresAt = leaseExpiresAt
        filters = try subscriptionFilters.map {
            guard JSONSerialization.isValidJSONObject($0) else {
                throw EncodingError.invalidValue($0, .init(
                    codingPath: [CodingKeys.filters],
                    debugDescription: "Subscription filters must contain only JSON values"
                ))
            }
            let data = try JSONSerialization.data(withJSONObject: $0)
            return try JSONDecoder().decode([[String: PushJSONValue]].self, from: data)
        }
    }
}
