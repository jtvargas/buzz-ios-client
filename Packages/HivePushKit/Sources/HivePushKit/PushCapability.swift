import Foundation

/// The push capability a relay advertises in its NIP-11 information document.
///
/// Parsed from the `"push"` object in the relay's information document. When
/// present and this app's profile is listed, the relay supports NIP-PL push
/// notification leases and the client may start enrollment.
///
/// # What it tells us
///
/// - Whether push is supported at all (presence of the object).
/// - Which app profiles the relay accepts (must include our `"buzz-ios-dogfood"`).
/// - The relay's push signing key (needed for the gateway delegation step).
/// - The event kinds the relay will forward through push.
public struct PushCapability: Equatable, Sendable {
    /// The relay push signing keys. The `current` key is what we delegate to.
    public let keys: [PushKey]
    /// App profiles this relay accepts.
    public let appProfiles: [AppProfile]
    /// The event kinds the relay will push.
    public let pushKinds: [Int]
    /// The relay's push origin URL.
    public let origin: String?

    /// The current relay push key, used for the delegation step.
    public var currentKey: PushKey? {
        keys.first { $0.isCurrent }
    }

    /// Whether this relay supports our app profile.
    public var supportsHive: Bool {
        appProfiles.contains { $0.id == PushConstants.appProfile }
    }

    /// Whether this relay supports a specific app profile.
    public func supports(appProfile: String) -> Bool {
        appProfiles.contains { $0.id == appProfile }
    }

    public struct PushKey: Equatable, Sendable {
        public let id: String
        public let pubkey: String
        public let isCurrent: Bool

        public init(id: String, pubkey: String, isCurrent: Bool) {
            self.id = id
            self.pubkey = pubkey
            self.isCurrent = isCurrent
        }
    }

    public struct AppProfile: Equatable, Sendable {
        public let id: String
        public let transport: String

        public init(id: String, transport: String) {
            self.id = id
            self.transport = transport
        }
    }
}

// MARK: - Parsing from NIP-11

public extension PushCapability {
    /// Parses from the `"push"` JSON object in a NIP-11 information document.
    /// Returns `nil` if the data does not contain a push object or it is malformed.
    static func parse(fromRelayInfoData data: Data) -> PushCapability? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let push = json["push"] as? [String: Any]
        else { return nil }

        let keys: [PushKey] = (push["keys"] as? [[String: Any]])?.compactMap { keyObj in
            guard let id = keyObj["id"] as? String,
                  let pubkey = keyObj["pubkey"] as? String
            else { return nil }
            let current = keyObj["current"] as? Bool ?? false
            return PushKey(id: id, pubkey: pubkey, isCurrent: current)
        } ?? []

        let profiles: [AppProfile] = (push["app_profiles"] as? [[String: Any]])?.compactMap { obj in
            guard let id = obj["id"] as? String,
                  let transport = obj["transport"] as? String
            else { return nil }
            return AppProfile(id: id, transport: transport)
        } ?? []

        let pushKinds = (push["push_kinds"] as? [Int]) ?? []
        let origin = push["origin"] as? String

        return PushCapability(
            keys: keys,
            appProfiles: profiles,
            pushKinds: pushKinds,
            origin: origin
        )
    }
}
