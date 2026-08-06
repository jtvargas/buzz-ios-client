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

    @Test func intentRejectsAnIdentifierFromAnotherActiveCommunity() {
        #expect(throws: ConversationEntityError.otherCommunity) {
            try OpenConversationIntent.validate(
                EntityID(community: UUID(), native: "ios"),
                activeCommunityID: UUID()
            )
        }
    }
}
