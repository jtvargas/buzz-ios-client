import BuzzKit
import Foundation

/// The dependency-free persisted answer available before Hive's view tree or session exists.
///
/// `EntityQuery` can run before `HiveApp.body`, so this type talks to `UserDefaults.standard`
/// directly and holds no reference to `AppEnvironment`, the live indexer or an app dependency.
struct ConversationEntitySnapshotStore: Sendable {
    struct Snapshot: Codable, Equatable, Sendable {
        let communityID: UUID
        let entries: [Entry]
    }

    struct Entry: Codable, Equatable, Sendable {
        let id: EntityID
        let name: String
        let kind: String
        let isPrivate: Bool

        init(_ entity: ConversationEntity) {
            id = entity.id
            name = entity.name
            kind = entity.kind
            isPrivate = entity.isPrivate
        }

        var entity: ConversationEntity {
            ConversationEntity(id: id, name: name, kind: kind, isPrivate: isPrivate)
        }
    }

    private let key: String

    init(key: String = "conversation-entities.snapshot.v1") {
        self.key = key
    }

    func load() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    func save(communityID: UUID, entities: [ConversationEntity]) {
        let snapshot = Snapshot(communityID: communityID, entries: entities.map(Entry.init))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    func entity(id: EntityID) -> ConversationEntity? {
        load()?.entries.first(where: { $0.id == id })?.entity
    }

    func fallbackRow(id: EntityID) -> ChannelListRow? {
        guard let entity = entity(id: id) else { return nil }
        return ChannelListRow(
            id: entity.id.native,
            name: entity.name,
            about: nil,
            picture: nil,
            isPrivate: entity.isPrivate,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
    }
}
