import Foundation
import Testing
@testable import Hive

@MainActor
@Suite struct AppTargetTests {
    @Test func existingDestinationsRemainNavigationTargets() {
        let navigator = AppNavigator()

        for destination in AppDestination.allCases {
            navigator.request(.destination(destination))
            #expect(navigator.pending == .destination(destination))
        }
    }

    @Test func dynamicConversationAndThreadTargetsRetainTheirIdentifiers() {
        let navigator = AppNavigator()
        let id = EntityID(community: UUID(), native: "ios")
        navigator.request(.conversation(id))
        #expect(navigator.pending == .conversation(id))

        navigator.request(.thread(channelID: "ios", rootID: "event"))
        #expect(navigator.pending == .thread(channelID: "ios", rootID: "event"))
    }
}
