import Foundation
import Testing
@testable import Hive

@Suite struct ConversationEntitySnapshotTests {
    @Test func aFreshStoreReadsThePersistedColdLaunchSnapshot() {
        let key = "conversation-snapshot-\(UUID().uuidString)"
        let writer = ConversationEntitySnapshotStore(key: key)
        defer { writer.clear() }
        let community = UUID()
        let entity = ConversationEntity(
            id: EntityID(community: community, native: "ios"),
            name: "ios",
            isPrivate: true
        )
        writer.save(communityID: community, entities: [entity])

        let coldReader = ConversationEntitySnapshotStore(key: key)

        #expect(coldReader.load()?.communityID == community)
        #expect(coldReader.entity(id: entity.id) == entity)
        #expect(coldReader.fallbackRow(id: entity.id)?.name == "ios")
    }
}
