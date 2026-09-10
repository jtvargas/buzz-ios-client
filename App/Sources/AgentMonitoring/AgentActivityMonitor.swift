import ActivityKit
import BuzzKit
import Foundation
import Observation
import UIKit

/// Experimental, app-owned monitoring. No relay connection lives in the widget.
/// The app holds its usual connection only while iOS grants a monitoring window.
@MainActor
@Observable
final class AgentActivityMonitor {
    private(set) var status = "Not monitoring"
    private(set) var isMonitoring = false
    private(set) var isStarting = false
    private(set) var isStopping = false
    private(set) var roster: [AgentActivityAttributes.AgentRow] = []
    private(set) var agentCount = 0
    private(set) var sessionEndsAt: Date?
    private(set) var lastUpdate: Date?
    private(set) var hasAttemptedStart = false
    var isArmed = false

    @ObservationIgnored let runtime = AgentMonitoringRuntime()
    @ObservationIgnored let writer = AgentLiveActivityWriter()
    @ObservationIgnored var sessionID: UUID?
    @ObservationIgnored var work: Task<Void, Never>?
    @ObservationIgnored var engine: SyncEngine?
    @ObservationIgnored var lastState: AgentActivityAttributes.ContentState?
    @ObservationIgnored var isAppForeground = true
    @ObservationIgnored private var stoppingTask: Task<Void, Never>?
    @ObservationIgnored var triggerTask: Task<Void, Never>?
    @ObservationIgnored var triggerEligibleAfter = ContinuousClock.now

    func start(
        engine: SyncEngine, store: BuzzEventStore, community: Community, selfPubkey: String?,
        initialRows: [AgentActivityAttributes.AgentRow], metadata: AgentMonitoringMetadata
    ) {
        guard !isStarting, !isMonitoring, !isStopping, !initialRows.isEmpty else { return }
        guard UIApplication.shared.applicationState == .active else {
            status = "Open Hive to start monitoring"
            return
        }
        hasAttemptedStart = true
        let id = UUID()
        sessionID = id
        self.engine = engine
        isAppForeground = true
        isStarting = true
        status = "Starting monitoring…"
        let end = Date.now.addingTimeInterval(AgentMonitoringRuntime.duration)
        sessionEndsAt = end
        let count = Set(initialRows.map(\.pubkey)).count
        let initial = AgentActivityAttributes.ContentState(
            rows: Self.widgetRows(initialRows), agentCount: count, scopeCount: initialRows.count,
            status: .working, updatedAt: .now,
            sessionEndsAt: end, isForegroundOnly: true
        )
        lastState = initial
        applyRoster(initialRows, count: count, label: "\(count) \(count == 1 ? "agent" : "agents") working")
        // Request execution only after actual agent activity, before card setup.
        retryBackgroundAccess(immediately: true)
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await writer.start(
                    attributes: AgentActivityAttributes(
                        communityID: community.id.uuidString, communityName: String(community.name.prefix(48))
                    ), state: initial
                )
                guard sessionID == id, !Task.isCancelled else { return }
                isStarting = false
                isMonitoring = true
                await run(id: id, engine: engine, store: store, selfPubkey: selfPubkey, initialMetadata: metadata)
                await engine.retainConnectionForMonitoring(false)
            } catch is CancellationError {
                // Stop owns cleanup and waits for this operation before ending the card.
            } catch {
                guard sessionID == id else { return }
                let message = error is AgentLiveActivityWriter.WriterError
                    ? "Allow Live Activities for Hive in iOS Settings"
                    : "Live Activity unavailable: \(error.localizedDescription)"
                requestStop(message: message, immediately: false, succeeded: false)
            }
        }
    }

    func requestStop(message: String = "Monitoring stopped", immediately: Bool = true, succeeded: Bool = true) {
        Task { await stop(message: message, immediately: immediately, succeeded: succeeded) }
    }

    func stop(message: String = "Monitoring stopped", immediately: Bool = true, succeeded: Bool = true) async {
        disarm()
        if let stoppingTask {
            await stoppingTask.value
            return
        }
        isStopping = true
        sessionID = nil
        let previous = work
        previous?.cancel()
        let cleanup = Task {
            await finishStopping(previous: previous, message: message, immediately: immediately, succeeded: succeeded)
            stoppingTask = nil
            isStopping = false
        }
        stoppingTask = cleanup
        await cleanup.value
    }

    private func finishStopping(
        previous: Task<Void, Never>?, message: String, immediately: Bool, succeeded: Bool
    ) async {
        // Do not release iOS runtime until the final ActivityKit write and relay
        // ownership cleanup have finished. Cancellation/kill may still interrupt us.
        await previous?.value
        await engine?.retainConnectionForMonitoring(false)
        engine = nil
        work = nil
        var final = lastState
        final?.status = immediately ? .ended : .paused
        final?.agentCount = 0
        final?.rows = []
        await writer.finish(final, dismissImmediately: immediately)
        runtime.finish(success: succeeded)
        roster = []
        agentCount = 0
        isStarting = false
        isMonitoring = false
        sessionEndsAt = nil
        status = message
    }

    func applyRoster(_ rows: [AgentActivityAttributes.AgentRow], count: Int, label: String) {
        if roster != rows { roster = rows }
        if agentCount != count { agentCount = count }
        if status != label { status = label }
    }

    func publish(_ state: AgentActivityAttributes.ContentState) {
        lastState = state
        lastUpdate = state.updatedAt
        writer.update(state)
    }

    func resetForCommunityChange() async {
        await stop()
        hasAttemptedStart = false
        lastUpdate = nil
        lastState = nil
    }
}
