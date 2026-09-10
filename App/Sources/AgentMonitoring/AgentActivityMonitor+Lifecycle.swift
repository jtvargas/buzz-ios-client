import SwiftUI
import UIKit

extension AgentActivityMonitor {
    var canObserveActivity: Bool { isAppForeground || runtime.hasExecutionTime }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            if !isAppForeground {
                triggerEligibleAfter = .now
                resetAutomaticRecovery()
            }
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
        applyRoster([], count: 0, label: "Paused · Resumes automatically when Hive is open")
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
