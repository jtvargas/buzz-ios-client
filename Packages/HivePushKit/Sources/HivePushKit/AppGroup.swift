import Foundation

/// The App Group the app and its Notification Service Extension share, resolved
/// from the bundle each process runs in.
///
/// The identifier is written once, in `Config/Shared.xcconfig`
/// (`HIVE_APP_GROUP_IDENTIFIER`), and reaches every target's entitlements and
/// Info.plist from there (`project.yml`). Reading it back out of the Info.plist
/// is what keeps this file free of a second copy that could drift from the
/// entitlement that actually grants access.
public struct AppGroup: Sendable {
    /// The Info.plist key both targets carry the identifier under.
    public static let infoPlistKey = "HiveAppGroupIdentifier"

    /// The `group.…` identifier, as granted by the entitlement.
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }

    /// The group declared in `bundle`'s Info.plist, or `nil` when the bundle was
    /// built without one — which no shipped target is, so a `nil` here is a build
    /// configuration fault rather than a state to design around.
    public init?(bundle: Bundle = .main) {
        guard let identifier = bundle.object(forInfoDictionaryKey: Self.infoPlistKey) as? String,
              !identifier.isEmpty
        else { return nil }
        self.init(identifier: identifier)
    }

    /// The shared container's root, or `nil` when this process holds no entitlement
    /// for the group. The system creates the directory on first ask.
    public var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
