import AppIntents
import Foundation

/// A stable entity handle whose community boundary survives outside Hive.
///
/// Spotlight and saved shortcuts keep entity identifiers across launches and app updates.
/// A channel UUID alone cannot say which of Hive's per-community stores owns it, so the
/// community UUID is part of the persisted value rather than inferred from the open store.
struct EntityID: Codable, Hashable, LosslessStringConvertible, Sendable {
    let community: UUID
    let native: String

    init(community: UUID, native: String) {
        self.community = community
        self.native = native
    }

    init?(_ description: String) {
        guard let separator = description.firstIndex(of: ":"),
              let community = UUID(uuidString: String(description[..<separator]))
        else { return nil }
        let native = String(description[description.index(after: separator)...])
        guard !native.isEmpty else { return nil }
        self.init(community: community, native: native)
    }

    var description: String {
        "\(community.uuidString.lowercased()):\(native)"
    }
}

extension EntityID: EntityIdentifierConvertible {
    var entityIdentifierString: String { description }

    static func entityIdentifier(for entityIdentifierString: String) -> EntityID? {
        EntityID(entityIdentifierString)
    }
}
