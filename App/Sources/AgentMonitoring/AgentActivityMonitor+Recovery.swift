import BuzzKit
import Foundation
import OSLog
import UIKit

extension AgentActivityMonitor {
    func resetAutomaticRecovery() {
        nextAutomaticRetryAt = nil
        automaticRetryDelay = .seconds(30)
        waitsForForegroundReturn = false
    }

    /// Only foreground, relay-confirmed work can retry. The existing two-second
    /// monitoring tick drives this; no extra timer or connection is created.
    func recoverBackgroundIfNeeded(
        records: [PresenceStore.MonitoredActivity], metadata: AgentMonitoringMetadata,
        ready: Bool, selfPubkey: String?
    ) {
        guard isMonitoring, !isStopping, isAppForeground,
              UIApplication.shared.applicationState == .active else { return }
        if runtime.isActive {
            nextAutomaticRetryAt = nil
            automaticRetryDelay = .seconds(30)
            return
        }
        guard ready, !waitsForForegroundReturn, !runtime.isRequesting,
              records.contains(where: {
                  $0.receivedAt >= triggerEligibleAfter && $0.pubkey != selfPubkey
                      && metadata.names.isAgent($0.pubkey)
              }) else { return }
        if let nextAutomaticRetryAt, ContinuousClock.now < nextAutomaticRetryAt { return }
        requestBackgroundMonitoring()
    }

    /// Called once on initial working activity and thereafter with foreground
    /// backoff. A second heartbeat never replaces an in-flight scheduler request.
    func requestBackgroundMonitoring() {
        guard isMonitoring || isStarting, !isStopping, isAppForeground,
              UIApplication.shared.applicationState == .active,
              !runtime.isActive, !runtime.isRequesting else { return }
        nextAutomaticRetryAt = ContinuousClock.now.advanced(by: automaticRetryDelay)
        automaticRetryDelay = min(automaticRetryDelay * 2, .seconds(120))
        Logger(subsystem: "Hive", category: "AgentMonitoring.recovery")
            .notice("Requesting background monitoring for foreground agent activity")
        runtime.request(immediately: true, expired: { [weak self] in
            self?.backgroundRuntimeExpired()
        }, windowEnded: { [weak self] in self?.pauseIfNeeded() })
    }

    private func backgroundRuntimeExpired() {
        // Expiration can also mean the reader cancelled the system progress card.
        // Do not immediately recreate it. A new foreground visit and fresh work
        // are required, while the custom card/session can still resume normally.
        waitsForForegroundReturn = true
        runtime.finish(success: false)
        pauseIfNeeded()
    }
}
