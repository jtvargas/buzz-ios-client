import ActivityKit
import BuzzKit
import Foundation

extension AgentActivityMonitor {
    func run(id: UUID, engine: SyncEngine, store: BuzzEventStore, selfPubkey: String?) async {
        let started = ContinuousClock.now
        var metadata = AgentMonitoringMetadata.empty
        var metadataReadAt = started.advanced(by: .seconds(-30))
        var publishedAt = started.advanced(by: .seconds(-10))
        var retainedConnection = false
        while sessionID == id, !Task.isCancelled {
            let instant = ContinuousClock.now
            let elapsed = started.duration(to: instant).components.seconds
            if elapsed >= Int64(AgentMonitoringRuntime.duration) {
                requestStop(message: "30-minute session ended. Start another in Settings.", immediately: false)
                return
            }
            if writer.activity?.activityState == .dismissed || writer.activity?.activityState == .ended {
                requestStop(message: "Live Activity dismissed")
                return
            }
            if retainedConnection != runtime.hasExecutionTime {
                retainedConnection = runtime.hasExecutionTime
                await engine.retainConnectionForMonitoring(retainedConnection)
                guard sessionID == id, !Task.isCancelled else { return }
            }
            if !canObserveActivity {
                pauseIfNeeded()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                continue
            }
            if metadataReadAt.duration(to: instant) >= .seconds(15) {
                if let updated = try? await AgentMonitoringMetadata.read(store: store, selfPubkey: selfPubkey) {
                    metadata = updated
                }
                metadataReadAt = instant
            }
            let ready = await engine.refreshMonitoringConnection()
            let records = await engine.presenceStore.monitoredActivity()
            guard sessionID == id, !Task.isCancelled else { return }
            // A background transition can happen while the reads above await.
            // Never overwrite its Paused card with an in-flight working snapshot.
            guard canObserveActivity else { pauseIfNeeded(); continue }
            if publishActivity(
                records: records, metadata: metadata, ready: ready, selfPubkey: selfPubkey,
                refresh: publishedAt.duration(to: instant) >= .seconds(4)
            ) {
                publishedAt = instant
            }
            runtime.report(elapsed: Double(elapsed), agentCount: agentCount)
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    private func publishActivity(
        records: [PresenceStore.MonitoredActivity], metadata: AgentMonitoringMetadata,
        ready: Bool, selfPubkey: String?, refresh: Bool
    ) -> Bool {
        let rows = ready ? Self.rows(records: records, metadata: metadata, selfPubkey: selfPubkey) : []
        let count = Set(rows.map(\.pubkey)).count
        let activityStatus: AgentActivityAttributes.Status = !ready ? .reconnecting : count > 0 ? .working : .waiting
        let label = activityStatus == .working
            ? "\(count) \(count == 1 ? "agent" : "agents") working" : activityStatus.label
        applyRoster(rows, count: count, label: label)
        let widgetRows = Self.widgetRows(rows)
        // Refresh freshness even with an unchanged roster; a frozen process must
        // not leave an apparently live count behind indefinitely.
        guard refresh || lastState?.status != activityStatus || lastState?.rows != widgetRows
            || lastState?.isForegroundOnly != !runtime.hasExecutionTime
            || lastState?.isTemporaryBackground != (runtime.graceWindow.isActive && !runtime.isActive)
            || lastState?.agentCount != count else { return false }
        publish(AgentActivityAttributes.ContentState(
            rows: widgetRows, agentCount: count, scopeCount: rows.count, status: activityStatus,
            updatedAt: .now, sessionEndsAt: sessionEndsAt ?? .now, isForegroundOnly: !runtime.hasExecutionTime,
            isTemporaryBackground: runtime.graceWindow.isActive && !runtime.isActive
        ))
        return true
    }

    private static func rows(
        records: [PresenceStore.MonitoredActivity], metadata: AgentMonitoringMetadata, selfPubkey: String?
    ) -> [AgentActivityAttributes.AgentRow] {
        records.filter { $0.pubkey != selfPubkey && metadata.names.isAgent($0.pubkey) }.map { record in
            AgentActivityAttributes.AgentRow(
                pubkey: record.pubkey, name: String(metadata.names.name(for: record.pubkey).prefix(48)),
                initials: metadata.names.initials(for: record.pubkey), channelID: record.channel,
                channelName: String(metadata.names.conversation(for: record.channel).title.prefix(48)),
                threadID: record.thread
            )
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    private static func widgetRows(_ rows: [AgentActivityAttributes.AgentRow]) -> [AgentActivityAttributes.AgentRow] {
        var seen: Set<String> = []
        return Array(rows.filter { seen.insert($0.pubkey).inserted }.prefix(3))
    }
}
