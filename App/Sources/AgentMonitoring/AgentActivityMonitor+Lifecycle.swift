import SwiftUI
import UIKit

extension AgentActivityMonitor {
    var canObserveActivity: Bool { isAppForeground || runtime.isActive }

    func retryBackgroundAccess() {
        guard isMonitoring, !isStopping, isAppForeground,
              UIApplication.shared.applicationState == .active else { return }
        runtime.request { [weak self] in
            self?.requestStop(message: "iOS interrupted monitoring", immediately: false, succeeded: false)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppForeground = true
        case .background:
            isAppForeground = false
            guard isMonitoring || isStarting else { return }
            runtime.enteredBackground()
            pauseIfNeeded()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func pauseIfNeeded() {
        guard isMonitoring, !isStopping, !canObserveActivity,
              var state = lastState, state.status != .paused else { return }
        applyRoster([], count: 0, label: "Paused · Open Hive to resume")
        state.status = .paused
        state.rows = []
        state.agentCount = 0
        state.scopeCount = 0
        state.isForegroundOnly = true
        state.updatedAt = .now
        publish(state)
    }
}
