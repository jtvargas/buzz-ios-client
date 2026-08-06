import AppIntents
import Foundation
import Testing
@testable import Hive

@Suite struct EntityIDTests {
    @Test func roundTripsThroughEntityIdentifier() {
        let id = EntityID(
            community: UUID(uuidString: "4b8dad6a-25a5-47f7-a1dd-72f35190a8f8")!,
            native: "channel:with-a-separator"
        )

        let identifier = EntityIdentifier(for: ConversationEntity.self, identifier: id)

        #expect(identifier.identifier == id.description)
        #expect(EntityID.entityIdentifier(for: identifier.identifier) == id)
    }
}
