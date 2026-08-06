import Foundation
import Testing
@testable import Hive

@Suite struct CommunitySiriIndexingTests {
    @Test func currentBuildRoundTripPreservesTheOptionalPreference() throws {
        var community = Community.new(relayURLString: "wss://example.com")
        community.siriIndexingEnabled = false

        let decoded = try JSONDecoder().decode(
            Community.self,
            from: JSONEncoder().encode(community)
        )

        #expect(decoded == community)
        #expect(decoded.isSiriIndexingEnabled == false)
    }

    @Test func nilDefaultsToReachable() {
        let community = Community.new(relayURLString: "wss://example.com")
        #expect(community.siriIndexingEnabled == nil)
        #expect(community.isSiriIndexingEnabled)
    }
}
