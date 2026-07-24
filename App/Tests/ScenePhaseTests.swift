@testable import Hive
import SwiftUI
import Testing

/// Records the engine hooks the app would drive, so the mapping is asserted
/// without a live engine or any sleeps.
private actor SpyResponder: ScenePhaseResponder {
    enum Call: Equatable { case foreground, background }
    private(set) var calls: [Call] = []
    func enterForeground() { calls.append(.foreground) }
    func enterBackground() { calls.append(.background) }
}

@Suite("Scene-phase forwarding")
struct ScenePhaseTests {
    @Test("active → foreground, background → background, inactive ignored")
    func forwards() async {
        let spy = SpyResponder()

        await forwardScenePhase(.active, to: spy)
        await forwardScenePhase(.inactive, to: spy)
        await forwardScenePhase(.background, to: spy)

        #expect(await spy.calls == [.foreground, .background])
    }
}
