import BuzzKit
import Foundation
import OSLog
import UIKit

extension AgentActivityMonitor {
    /// Opt-in only installs a listener. A fresh relay heartbeat from a known agent,
    /// received while Hive is open, is required before creating any Live Activity.
    func arm(engine: SyncEngine, store: BuzzEventStore, community: Community, selfPubkey: String?) {
        guard !isArmed, !isStarting, !isMonitoring, !isStopping else { return }
        isArmed = true
        triggerEligibleAfter = .now
        applyRoster([], count: 0, label: "Waiting for an agent to start working")
        Logger(subsystem: "Hive", category: "AgentMonitoring.trigger").info("Waiting for relay agent activity")
        triggerTask = Task { [weak self] in
            let heartbeats = await engine.presenceStore.monitoringHeartbeats()
            var metadata = AgentMonitoringMetadata.empty
            var metadataReadAt = ContinuousClock.now.advanced(by: .seconds(-30))
            for await _ in heartbeats {
                guard let self, !Task.isCancelled, isArmed else { return }
                guard isAppForeground, UIApplication.shared.applicationState == .active else { continue }
                if metadataReadAt.duration(to: .now) >= .seconds(15) {
                    guard let updated = try? await AgentMonitoringMetadata.read(store: store, selfPubkey: selfPubkey)
                    else { continue }
                    metadata = updated
                    metadataReadAt = .now
                }
                let ready = await engine.refreshMonitoringConnection()
                let records = await engine.presenceStore.monitoredActivity()
                // Recheck after actor/database hops: toggle-off, community teardown,
                // or a screen lock must invalidate a trigger already in flight.
                guard !Task.isCancelled, isArmed else { return }
                guard ready, isAppForeground, UIApplication.shared.applicationState == .active,
                      records.contains(where: {
                          $0.receivedAt >= triggerEligibleAfter && $0.pubkey != selfPubkey
                              && metadata.names.isAgent($0.pubkey)
                      }) else { continue }
                let rows = Self.rows(records: records, metadata: metadata, selfPubkey: selfPubkey)
                Logger(subsystem: "Hive", category: "AgentMonitoring.trigger")
                    .notice("Relay agent activity confirmed; starting Live Activity")
                start(
                    engine: engine, store: store, community: community, selfPubkey: selfPubkey,
                    initialRows: rows, metadata: metadata
                )
                disarm()
                return
            }
        }
    }

    func disarm() {
        triggerTask?.cancel()
        triggerTask = nil
        isArmed = false
    }
}
