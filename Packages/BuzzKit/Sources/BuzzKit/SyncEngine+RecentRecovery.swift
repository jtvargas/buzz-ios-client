import Foundation
import NostrCore

extension SyncEngine {
    /// Cached access lets recent conversations start independently of directory
    /// revalidation. The server still authorizes each request; the directory pass
    /// later reconciles membership and cancels work for removed destinations.
    func startRecentWarmup(generation: Int) {
        guard directoryContext != nil else { return }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await warmRecentConversations(generation: generation)
            await finishRecentWarmup(id: id)
        }
        recovery.warmup = RecoveryContext.Job(id: id, generation: generation, task: task)
    }

    private func warmRecentConversations(generation: Int) async {
        guard let identity = selfPubkeyHex,
              let allowed = try? await store.activeChannelIDs(identity: identity),
              isCurrent(generation) else { return }
        let channels = Set(recentConversationDestinations.map(\.channelID)).intersection(allowed)
        let jobs = startChannelRecoveries(channels, generation: generation)
        async let threads: Void = recoverRecentThreads(allowedChannels: channels, generation: generation)
        for job in jobs {
            await job.value
        }
        await threads
    }

    private func finishRecentWarmup(id: UUID) {
        guard recovery.warmup?.id == id else { return }
        recovery.warmup = nil
    }

    /// Success is remembered per root and socket, so a failed warmup can be retried
    /// by the next directory/foreground pass. Concurrent passes share one task.
    func recoverRecentThreads(allowedChannels: Set<String>, generation: Int) async {
        guard isCurrent(generation) else { return }
        recovery.recentAllowed.formUnion(allowedChannels)
        if let job = recovery.recentThreads, job.generation == generation {
            await job.task.value
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await performRecentThreadRecovery(generation: generation)
            await finishRecentThreadRecovery(id: id)
        }
        recovery.recentThreads = RecoveryContext.Job(id: id, generation: generation, task: task)
        await task.value
    }

    private func performRecentThreadRecovery(generation: Int) async {
        var attempted: Set<String> = []
        while isCurrent(generation) {
            var seen = attempted.union(recovery.recoveredRoots)
            let roots = recentConversationDestinations.compactMap { destination -> String? in
                guard recovery.recentAllowed.contains(destination.channelID),
                      let root = destination.threadRootID, seen.insert(root).inserted else { return nil }
                return root
            }
            guard let first = roots.first else { return }
            let activeRoot = recentConversationDestinations.first.flatMap { destination in
                destination.channelID == activeChannel ? destination.threadRootID : nil
            }
            if first == activeRoot {
                attempted.insert(first)
                let alreadyLoaded = threadLoading.requests[first]?.state == .loaded
                let succeeded = if alreadyLoaded { true } else { await (try? openThread(root: first)) != nil }
                if succeeded {
                    guard isCurrent(generation) else { return }
                    recovery.recoveredRoots.insert(first)
                }
                continue
            }
            attempted.formUnion(roots)
            let filters = roots.map {
                Filter(kinds: [.channelMessage], limit: config.threadPrefetchReplyLimit, tagQueries: ["e": [$0]])
            }
            guard let events = try? await queryForRecovery(filters, destination: .thread(first), phase: .head),
                  isCurrent(generation),
                  let result = try? await store.ingest(batch: events, phase: .backfill),
                  result.rejected.isEmpty, isCurrent(generation) else { return }
            recovery.recoveredRoots.formUnion(roots)
        }
    }

    private func finishRecentThreadRecovery(id: UUID) {
        guard recovery.recentThreads?.id == id else { return }
        recovery.recentThreads = nil
    }
}
