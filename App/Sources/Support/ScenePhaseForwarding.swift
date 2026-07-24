import BuzzKit
import SwiftUI

/// The scene-phase side effects the app forwards to the sync engine — the only
/// thing the app tells the engine besides sending. Kept behind a protocol so the
/// forwarding logic is testable against a spy without a live engine (spec §Step 1
/// tests: "scene-phase calls forward").
protocol ScenePhaseResponder: Sendable {
    func enterForeground() async
    func enterBackground() async
}

extension SyncEngine: ScenePhaseResponder {}

/// Maps a SwiftUI scene phase onto the engine's foreground/background hooks.
///
/// `.active → enterForeground()`, `.background → enterBackground()`; `.inactive`
/// is a transient state (e.g. the app switcher) that the connection's own grace
/// window already covers, so it is deliberately ignored here (spec §Scene phase).
@Sendable
func forwardScenePhase(_ phase: ScenePhase, to responder: some ScenePhaseResponder) async {
    switch phase {
    case .active:
        await responder.enterForeground()
    case .background:
        await responder.enterBackground()
    case .inactive:
        break
    @unknown default:
        break
    }
}
