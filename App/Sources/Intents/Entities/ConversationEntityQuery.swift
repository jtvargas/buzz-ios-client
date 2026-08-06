import AppIntents
import Foundation

/// An honest failure for a saved entity whose community is no longer the one in scope.
///
/// It names no community. The id survives the record — a shortcut saved before a community was
/// removed still resolves to here — so any message naming the *other* side would have to look up
/// something it is allowed not to find.
///
/// `CustomLocalizedStringResourceConvertible` is what makes the sentence reach a person:
/// `LocalizedError` alone leaves Siri saying only that something went wrong.
enum ConversationEntityError: Error, LocalizedError, Equatable {
    case otherCommunity

    var errorDescription: String? {
        String(localized: Self.otherCommunityMessage)
    }

    static let otherCommunityMessage: LocalizedStringResource =
        "That channel isn't in the community you have open."
}

extension ConversationEntityError: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { Self.otherCommunityMessage }
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

    /// Foreign ids are dropped rather than failing the batch, and the refusal is spoken only
    /// when dropping them leaves nothing.
    ///
    /// The system may ask for several at once, and a stale id from a saved shortcut sitting
    /// beside live ones must not take the live ones down with it — an id this community does
    /// not own resolving to nothing *is* the framework's own not-found contract. The single-id
    /// case, which is what a spoken request actually is, still gets the sentence; and
    /// `perform()` re-checks against live state, which is where §4 says the boundary lives.
    func entities(for identifiers: [EntityID]) async throws -> [ConversationEntity] {
        guard let snapshot = snapshots.load() else { return [] }
        let requested = Set(identifiers.filter { $0.community == snapshot.communityID })
        guard !requested.isEmpty else {
            if identifiers.isEmpty { return [] }
            throw ConversationEntityError.otherCommunity
        }
        return snapshot.entries.lazy
            .filter { requested.contains($0.id) }
            .map(\.entity)
    }

    func suggestedEntities() async throws -> [ConversationEntity] {
        snapshots.load()?.entries.map(\.entity) ?? []
    }
}
