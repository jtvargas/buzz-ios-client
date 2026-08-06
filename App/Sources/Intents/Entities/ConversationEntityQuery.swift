import AppIntents
import Foundation

/// An honest failure for a saved entity whose community is no longer the one in scope.
enum ConversationEntityError: Error, LocalizedError, Equatable {
    case otherCommunity

    var errorDescription: String? {
        "That channel isn't in the community you have open."
    }
}

/// Resolves entirely from the cold-launch snapshot.
///
/// The query intentionally has no `@Dependency`: parameter resolution can precede every app
/// dependency and every session hook. The snapshot's own community id is the earliest safe
/// scope boundary; `OpenConversationIntent.perform()` repeats the check against live state.
struct ConversationEntityQuery: EntityQuery {
    private let snapshots: ConversationEntitySnapshotStore

    init() {
        snapshots = ConversationEntitySnapshotStore()
    }

    init(snapshots: ConversationEntitySnapshotStore) {
        self.snapshots = snapshots
    }

    func entities(for identifiers: [EntityID]) async throws -> [ConversationEntity] {
        guard let snapshot = snapshots.load() else { return [] }
        guard identifiers.allSatisfy({ $0.community == snapshot.communityID }) else {
            throw ConversationEntityError.otherCommunity
        }
        let requested = Set(identifiers)
        return snapshot.entries.lazy
            .filter { requested.contains($0.id) }
            .map(\.entity)
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        snapshots.load()?.entries.map(\.entity) ?? []
    }
}
