import SwiftUI
import UIKit

extension AgentActivityMonitor {
    var canObserveActivity: Bool { isAppForeground || runtime.hasExecutionTime }

    func retryBackgroundAccess(immediately: Bool = false) {
        guard isMonitoring || isStarting, !isStopping, isAppForeground,
              UIApplication.shared.applicationState == .active else { return }
        runtime.request(immediately: immediately, expired: { [weak self] in
            self?.requestStop(message: "iOS interrupted monitoring", immediately: false, succeeded: false)
        }, windowEnded: { [weak self] in self?.pauseIfNeeded() })
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isAppForeground { triggerEligibleAfter = .now }
            isAppForeground = true
            runtime.graceWindow.enteredForeground()
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
        state.isTemporaryBackground = false
        state.updatedAt = .now
        publish(state)
    }
}
