import Foundation

extension SyncEngine {
    func onReadyAuthoritative(generation: Int) async {
        defer { if generation == readyGeneration { readyWorkInFlight = false } }
        let channels = await refreshAuthoritativeDirectory(generation: generation)
        guard isCurrent(generation) else { return }

        await reconcileChannelSubscriptions(channels)
        guard isCurrent(generation) else { return }

        Task { [weak self] in
            await self?.requestPresenceSnapshot(generation: generation)
        }

        for channel in channels.sorted() {
            guard isCurrent(generation) else { return }
            await reconcile(channel, generation: generation)
        }

        guard isCurrent(generation) else { return }
        await requestDrain(generation: generation)
    }

    /// Fetches and atomically commits a full membership directory. Any failed,
    /// cancelled, partial, or superseded fetch returns the last good active set.
    func refreshAuthoritativeDirectory(generation: Int) async -> Set<String> {
        guard let directoryClient, let identity = selfPubkeyHex else { return [] }
        let previous = (try? await store.previouslyActiveChannelIDs(identity: identity)) ?? []
        let previousVisible = (try? await store.activeChannelIDs(identity: identity)) ?? []
        guard let durableGeneration = try? await store.beginChannelDirectoryRefresh(identity: identity) else {
            return previousVisible
        }
        directoryRefreshGeneration += 1
        let requestGeneration = directoryRefreshGeneration

        do {
            let snapshot = try await directoryClient.fetch(
                selfPubkey: identity,
                previouslyActiveChannels: previous
            )
            guard isCurrent(generation),
                  requestGeneration == directoryRefreshGeneration
            else {
                return (try? await store.activeChannelIDs(identity: identity)) ?? previousVisible
            }
            _ = try await store.applyChannelDirectorySnapshot(
                snapshot,
                identity: identity,
                generation: durableGeneration
            )
        } catch {
            return previousVisible
        }
        return (try? await store.activeChannelIDs(identity: identity)) ?? previousVisible
    }

    /// Coalesces notification-driven refreshes. A signal arriving during a pass
    /// requests exactly one additional pass, which captures state that may have
    /// changed after the in-flight query began.
    func requestDirectoryRefresh() {
        guard directoryClient != nil, state == .running, !isStopped else { return }
        if directoryRefreshInFlight {
            directoryRefreshPending = true
            return
        }
        directoryRefreshInFlight = true
        let generation = readyGeneration
        Task { [weak self] in
            await self?.runScheduledDirectoryRefresh(generation: generation)
        }
    }

    private func runScheduledDirectoryRefresh(generation: Int) async {
        repeat {
            directoryRefreshPending = false
            let channels = await refreshAuthoritativeDirectory(generation: generation)
            guard isCurrent(generation) else { break }
            await reconcileChannelSubscriptions(channels)
            for channel in channels.sorted() {
                guard isCurrent(generation) else { break }
                await reconcile(channel, generation: generation)
            }
        } while directoryRefreshPending && isCurrent(generation)
        directoryRefreshInFlight = false
    }
}
