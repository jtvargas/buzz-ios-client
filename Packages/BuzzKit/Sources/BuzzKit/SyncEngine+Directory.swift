import Foundation

extension SyncEngine {
    /// A fresh socket joins the same authoritative pass used by every other
    /// trigger. The coordinator owns subscription and head reconciliation, so a
    /// `.ready` that overlaps launch, foreground, membership, CLOSED, backstop, or
    /// pull refresh can never start a competing fetch.
    func onReadyAuthoritative(generation: Int) async {
        defer { if generation == readyGeneration { readyWorkInFlight = false } }
        _ = await requestDirectoryRefreshAndWait()
    }

    /// Retries both independent recovery paths. The socket stops waiting out any
    /// backoff while the signed HTTP directory is revalidated immediately.
    public func retryConnectionAndDirectory() async {
        guard !isStopped else { return }
        await connection.reconnectNow()
        _ = await requestDirectoryRefreshAndWait()
    }

    /// Notification-driven entry point. Every caller lands in one single-flight
    /// coordinator. A signal during a pass joins that pass and records only one
    /// coalesced follow-up, no matter how many other signals arrive beside it.
    func requestDirectoryRefresh() {
        guard directoryContext != nil,
              selfPubkeyHex != nil,
              !isStopped
        else { return }
        _ = directoryAttemptTask()
    }

    /// Joins the current directory attempt, or starts one, and returns when that
    /// attempt has reached an authoritative or cached-fallback verdict. Downstream
    /// history reconciliation may continue; launch presentation depends only on
    /// this directory boundary.
    func requestDirectoryRefreshAndWait() async -> ChannelDirectoryStatus {
        guard directoryContext != nil,
              selfPubkeyHex != nil,
              !isStopped
        else {
            return directoryContext?.status ?? .authoritative
        }

        return await directoryAttemptTask().value.status
    }

    private func directoryAttemptTask() -> Task<ChannelDirectoryRefreshResult, Never> {
        guard let directoryContext else {
            return Task {
                ChannelDirectoryRefreshResult(channels: [], joined: [], status: .authoritative)
            }
        }
        if let current = directoryContext.attemptTask {
            directoryRefreshPending = true
            return current
        }

        directoryRefreshInFlight = true
        setDirectoryStatus(.checking)
        directoryRefreshGeneration += 1
        let generation = directoryRefreshGeneration
        let attempt: Task<ChannelDirectoryRefreshResult, Never> = Task { [weak self] in
            guard let self else {
                return ChannelDirectoryRefreshResult(channels: [], joined: [], status: .cachedFallback)
            }
            return await self.fetchAuthoritativeDirectory()
        }
        directoryContext.attemptTask = attempt
        directoryContext.refreshTask = Task { [weak self] in
            let result = await attempt.value
            await self?.finishDirectoryAttempt(result, generation: generation)
        }
        return attempt
    }

    private func finishDirectoryAttempt(
        _ result: ChannelDirectoryRefreshResult,
        generation: Int
    ) async {
        guard let directoryContext,
              generation == directoryRefreshGeneration
        else { return }

        // Directory authority is independent of the socket, but live
        // subscriptions and head windows are not. Reconcile only against the
        // socket generation current after the fetch, and abandon immediately if
        // a reconnect supersedes it.
        await reconcileAuthoritativeChannels(result.joined)
        guard generation == directoryRefreshGeneration else { return }

        directoryContext.attemptTask = nil
        directoryContext.refreshTask = nil
        if directoryRefreshPending, !isStopped {
            directoryRefreshPending = false
            _ = directoryAttemptTask()
        } else {
            directoryRefreshInFlight = false
        }
    }

    /// Fetches and atomically commits a full membership directory. Any failed,
    /// cancelled, partial, rejected, or superseded fetch leaves the last good
    /// access rows untouched and returns them as the cached fallback.
    ///
    /// Membership is read on **every** path, success or failure, and never falls back to a
    /// remembered value. It comes from `channel_member`, a projection a failed fetch cannot
    /// narrow: a roster is replaced only by a newer kind 39002 and never by one failing to
    /// arrive. That is what makes it safe for ``reconcileChannelSubscriptions(_:)`` to
    /// *remove* against — see ``liveChannels(joined:)``.
    private func fetchAuthoritativeDirectory() async -> ChannelDirectoryRefreshResult {
        guard let directoryClient, let identity = selfPubkeyHex else {
            return ChannelDirectoryRefreshResult(channels: [], joined: [], status: .cachedFallback)
        }

        let previous = (try? await store.previouslyActiveChannelIDs(identity: identity)) ?? []
        let previousVisible = (try? await store.activeChannelIDs(identity: identity)) ?? []
        func joinedChannels() -> Set<String> {
            (try? store.joinedChannelIDs(identity: identity)) ?? []
        }
        guard let durableGeneration = try? await store.beginChannelDirectoryRefresh(identity: identity)
        else {
            setDirectoryStatus(.cachedFallback)
            return ChannelDirectoryRefreshResult(
                channels: previousVisible, joined: joinedChannels(), status: .cachedFallback
            )
        }

        do {
            let snapshot = try await directoryClient.fetch(
                selfPubkey: identity,
                previouslyActiveChannels: previous
            )
            let committed = try await store.applyChannelDirectorySnapshot(
                snapshot,
                identity: identity,
                generation: durableGeneration
            )
            guard committed else {
                let visible = (try? await store.activeChannelIDs(identity: identity)) ?? previousVisible
                setDirectoryStatus(.cachedFallback)
                return ChannelDirectoryRefreshResult(
                    channels: visible, joined: joinedChannels(), status: .cachedFallback
                )
            }

            let visible = (try? await store.activeChannelIDs(identity: identity)) ?? previousVisible
            directoryContext?.refusedMembership = false
            setDirectoryStatus(.authoritative)
            return ChannelDirectoryRefreshResult(
                channels: visible, joined: joinedChannels(), status: .authoritative
            )
        } catch {
            // Recorded rather than thrown. Every failure still ends in the same cached
            // fallback, because a running workspace that dropped its sidebar over one
            // refusal would be worse than one showing what it last knew — this only
            // remembers *which* failure it was, for the identity gate to ask about.
            directoryContext?.refusedMembership = (error as? ChannelDirectoryError) == .membershipRequired
            setDirectoryStatus(.cachedFallback)
            return ChannelDirectoryRefreshResult(
                channels: previousVisible, joined: joinedChannels(), status: .cachedFallback
            )
        }
    }

    private func reconcileAuthoritativeChannels(_ joined: Set<String>) async {
        guard state == .running, !isStopped else { return }
        let generation = readyGeneration
        guard isCurrent(generation) else { return }

        let live = liveChannels(joined: joined)
        await reconcileChannelSubscriptions(live)
        guard isCurrent(generation) else { return }

        Task { [weak self] in
            await self?.requestPresenceSnapshot(generation: generation)
        }

        for channel in live.sorted() {
            guard isCurrent(generation) else { return }
            await reconcile(channel, generation: generation)
        }

        guard isCurrent(generation) else { return }
        await requestDrain(generation: generation)

        // Last, and after the drain: the reader's own queued sends must not wait behind a
        // launch's worth of reply fetching. Every part of it needs the head windows above
        // to have committed — a join hydrates against them, and a reply prefetch has no
        // candidates until the roots are held locally (``ThreadPrefetch``).
        //
        // Starters first, then everything else. The starter pass asks per channel and so
        // holds its two channels' place ahead of a budget spent in recency order; the pass
        // behind it covers every other channel the reader is in, which nothing on this path
        // did before. See ``SyncEngine/settleThreadPrefetch(generation:)``.
        guard isCurrent(generation) else { return }
        await settleStarterChannels(joined: joined, generation: generation)

        guard isCurrent(generation) else { return }
        await settleThreadPrefetch(generation: generation)
    }

    private func setDirectoryStatus(_ status: ChannelDirectoryStatus) {
        guard let directoryContext, directoryContext.status != status else { return }
        directoryContext.status = status
        for continuation in directoryStatusObservers.values {
            continuation.yield(status)
        }
    }
}
