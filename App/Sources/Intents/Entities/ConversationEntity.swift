import AppIntents
import CoreSpotlight
import Foundation

/// A channel Hive can name to Siri, Spotlight and the Shortcuts app.
///
/// DMs will use this same noun later, but phase 1 indexes channels only. Keeping the kind
/// discriminator now preserves that additive path without publishing anybody's DM title.
struct ConversationEntity: AppEntity, IndexedEntity, Hashable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Conversation",
        numericFormat: "\(placeholder: .int) conversations"
    )
    static let defaultQuery = ConversationEntityQuery()

    let id: EntityID

    /// The only property deliberately made searchable. A channel name is the phrase the
    /// feature exists to resolve; topics and identifiers stay out of the semantic index.
    @Property(title: "Name", indexingKey: \.displayName)
    var name: String

    @Property(title: "Kind")
    var kind: String

    @Property(title: "Private")
    var isPrivate: Bool

    init(id: EntityID, name: String, kind: String = "channel", isPrivate: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isPrivate = isPrivate
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: .init(systemName: "number"))
    }

    static func == (lhs: ConversationEntity, rhs: ConversationEntity) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.kind == rhs.kind
            && lhs.isPrivate == rhs.isPrivate
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(kind)
        hasher.combine(isPrivate)
    }
}
