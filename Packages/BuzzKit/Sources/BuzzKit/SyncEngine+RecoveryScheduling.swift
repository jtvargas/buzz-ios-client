import Foundation
import NostrCore

/// Engine-isolated ownership; the scheduler itself only grants request permits.
final class RecoveryContext {
    struct Job {
        let id: UUID
        let generation: Int
        let task: Task<Void, Never>
    }

    var channels: [String: Job] = [:]
    var lastHeads: [String: Date] = [:]
    var catchup: Job?
    var warmup: Job?
    var recentThreads: Job?
    var recentAllowed: Set<String> = []
    var recoveredRoots: Set<String> = []
}

extension SyncEngine {
    func updateRecoveryPriorities() async {
        var priorities: [RecoveryRequestScheduler.Destination] = []
        var visible: Set<RecoveryRequestScheduler.Destination> = []
        if let activeChannel {
            visible.insert(.channel(activeChannel))
            if let destination = recentConversationDestinations.first,
               destination.channelID == activeChannel, let root = destination.threadRootID {
                visible.insert(.thread(root))
                priorities.append(.thread(root))
            }
            priorities.append(.channel(activeChannel))
        }
        for destination in recentConversationDestinations {
            if let root = destination.threadRootID { priorities.append(.thread(root)) }
            priorities.append(.channel(destination.channelID))
        }
        await recoveryScheduler.prioritise(priorities, visible: visible)
    }

    func queryForRecovery(
        _ filters: [Filter],
        destination: RecoveryRequestScheduler.Destination = .background,
        phase: RecoveryRequestScheduler.Phase = .speculative
    ) async throws -> [NostrEvent] {
        let generation = readyGeneration
        guard isCurrent(generation) else { throw CancellationError() }
        // Wait outside admission so a relay budget pause does not occupy the
        // background slot while an HTTP head could already be useful.
        while true {
            try await subscriptions.waitForQueryAllowance()
            let permit = try await recoveryScheduler.acquire(destination, phase: phase)
            do {
                guard isCurrent(generation) else { throw CancellationError() }
                let result = try await subscriptions.queryIfAllowed(filters)
                guard isCurrent(generation) else { throw CancellationError() }
                await recoveryScheduler.release(permit)
                if let result { return result }
            } catch {
                await recoveryScheduler.release(permit)
                throw error
            }
        }
    }

    func fetchRecoveryWindow(
        _ filter: WindowFilter,
        channel: String,
        phase: RecoveryRequestScheduler.Phase
    ) async throws -> WindowResult {
        let generation = readyGeneration
        guard isCurrent(generation) else { throw CancellationError() }
        let permit = try await recoveryScheduler.acquire(.channel(channel), phase: phase)
        do {
            guard isCurrent(generation) else { throw CancellationError() }
            let result = try await windowClient.fetch(filter)
            guard isCurrent(generation) else { throw CancellationError() }
            await recoveryScheduler.release(permit)
            return result
        } catch {
            await recoveryScheduler.release(permit)
            throw error
        }
    }

    /// Enqueue heads together. Each job yields admission between pages, so the
    /// next channel's head is not held behind the previous channel's whole gap.
    func reconcileChannels(_ channels: Set<String>, generation: Int) async {
        guard isCurrent(generation) else { return }
        await updateRecoveryPriorities()
        let jobs = startChannelRecoveries(channels, generation: generation)
        for job in jobs {
            await job.value
            guard isCurrent(generation) else { return }
        }
    }

    func startChannelRecoveries(_ channels: Set<String>, generation: Int) -> [Task<Void, Never>] {
        guard isCurrent(generation) else { return [] }
        return recentChannelOrder(among: channels).map { channelRecovery($0, generation: generation) }
    }

    func reconcile(_ channel: String, generation: Int) async {
        guard isCurrent(generation) else { return }
        await channelRecovery(channel, generation: generation).value
    }

    /// An actual navigation earns a fresh head even when the live subscription
    /// already exists. Rapid returns share a recently fetched head. Restarting an
    /// unfinished gap is safe: its durable watermark has not moved, and its already
    /// committed pages remain in the log while the fresh pass closes that gap.
    func refreshVisibleChannel(_ channel: String) {
        guard state == .running, !isStopped else { return }
        if let lastHead = recovery.lastHeads[channel], now().timeIntervalSince(lastHead) < 5 { return }
        cancelChannelRecovery(channel)
        _ = channelRecovery(channel, generation: readyGeneration)
    }

    private func channelRecovery(_ channel: String, generation: Int) -> Task<Void, Never> {
        if let job = recovery.channels[channel], job.generation == generation { return job.task }
        let isSynced = channelStates[channel] == .synced || channelStates[channel] == .fallbackSynced
        if let lastHead = recovery.lastHeads[channel], now().timeIntervalSince(lastHead) < 5, isSynced {
            return Task {}
        }
        cancelChannelRecovery(channel)
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await performChannelReconciliation(channel, generation: generation)
            await finishChannelRecovery(channel, id: id)
        }
        recovery.channels[channel] = RecoveryContext.Job(id: id, generation: generation, task: task)
        return task
    }

    private func finishChannelRecovery(_ channel: String, id: UUID) {
        guard recovery.channels[channel]?.id == id else { return }
        recovery.channels.removeValue(forKey: channel)
    }

    func cancelChannelRecovery(_ channel: String) {
        recovery.channels.removeValue(forKey: channel)?.task.cancel()
    }

    func cancelRecovery() {
        recovery.catchup?.task.cancel()
        recovery.catchup = nil
        recovery.warmup?.task.cancel()
        recovery.warmup = nil
        recovery.recentThreads?.task.cancel()
        recovery.recentThreads = nil
        recovery.recentAllowed.removeAll()
        recovery.recoveredRoots.removeAll()
        for job in recovery.channels.values {
            job.task.cancel()
        }
        recovery.channels.removeAll()
        recovery.lastHeads.removeAll()
    }

    /// A completed directory releases its single-flight slot before background
    /// catch-up. A subsequent directory refresh must not wait for every old page.
    func scheduleAuthoritativeRecovery(_ result: ChannelDirectoryRefreshResult) {
        guard state == .running, !isStopped else { return }
        recovery.catchup?.task.cancel()
        recovery.warmup?.task.cancel()
        recovery.warmup = nil
        recovery.recentThreads?.task.cancel()
        recovery.recentThreads = nil
        recovery.recentAllowed.removeAll()
        let generation = readyGeneration
        let id = UUID()
        readyWorkInFlight = true
        let task = Task { [weak self] in
            guard let self else { return }
            await reconcileAuthoritativeChannels(result)
            await finishAuthoritativeRecovery(id: id)
        }
        recovery.catchup = RecoveryContext.Job(id: id, generation: generation, task: task)
    }

    private func finishAuthoritativeRecovery(id: UUID) {
        guard recovery.catchup?.id == id else { return }
        recovery.catchup = nil
        readyWorkInFlight = false
    }
}
