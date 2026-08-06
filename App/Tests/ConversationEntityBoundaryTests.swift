import Foundation
import Testing
@testable import Hive

@Suite struct ConversationEntityBoundaryTests {
    @Test func queryRejectsAnIdentifierFromAnotherCommunity() async throws {
        let current = UUID()
        let key = "conversation-boundary-\(UUID().uuidString)"
        let snapshots = ConversationEntitySnapshotStore(key: key)
        defer { snapshots.clear() }
        snapshots.save(communityID: current, entities: [
            ConversationEntity(
                id: EntityID(community: current, native: "ios"),
                name: "ios",
                isPrivate: false
            )
        ])

        await #expect(throws: ConversationEntityError.otherCommunity) {
            _ = try await ConversationEntityQuery(snapshots: snapshots).entities(for: [
                EntityID(community: UUID(), native: "ios")
            ])
        }
    }

    /// A stale id from a saved shortcut must not take the live ids beside it down.
    ///
    /// The system asks for identifiers in batches, so failing the whole request on one foreign
    /// member would make an old shortcut break conversations that resolve perfectly well. The
    /// spoken refusal is reserved for the case where dropping the foreign ones leaves nothing,
    /// which is what a single spoken request actually is.
    @Test func queryResolvesTheLocalIdentifiersInAMixedBatch() async throws {
        let current = UUID()
        let key = "conversation-boundary-mixed-\(UUID().uuidString)"
        let snapshots = ConversationEntitySnapshotStore(key: key)
        defer { snapshots.clear() }
        let mine = EntityID(community: current, native: "ios")
        snapshots.save(communityID: current, entities: [
            ConversationEntity(id: mine, name: "ios", isPrivate: false)
        ])

        let resolved = try await ConversationEntityQuery(snapshots: snapshots).entities(for: [
            EntityID(community: UUID(), native: "design"),
            mine
        ])

        #expect(resolved.map(\.id) == [mine])
    }

    @Test func intentRejectsAnIdentifierFromAnotherActiveCommunity() {
        #expect(throws: ConversationEntityError.otherCommunity) {
            try OpenConversationIntent.validate(
                EntityID(community: UUID(), native: "ios"),
                activeCommunityID: UUID()
            )
        }
    }
}
