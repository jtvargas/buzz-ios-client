import Foundation

/// Arming subscriptions across reconnects, the EOSE-gated replay cursor, and the
/// pre-send validation that keeps a doomed filter off the wire.
extension SubscriptionManager {
    /// Re-arms every live subscription each time the connection returns to
    /// `ready`. A fresh socket is a fresh epoch, and every subscription must be
    /// re-`REQ`ed onto it exactly once.
    func handleReadinessChange(_ state: ConnectionState) async {
        let nowReady = (state == .ready)
        let transitionedToReady = nowReady && !connectionIsReady
        // Recorded before the awaits below so a reentrant state change during
        // re-arming cannot mistake this epoch for a new one.
        connectionIsReady = nowReady
        guard transitionedToReady else {
            // The socket went away. Every pending re-`REQ` was scheduled against a connection
            // that no longer exists, and the budget that refused them belonged to it too — a
            // fresh socket is not over budget until it says so itself. The next `.ready` re-arms
            // everything from scratch.
            if !nowReady { await resetForDisconnect() }
            return
        }

        readyEpoch += 1
        let epoch = readyEpoch
        await replay(armOrder(), epoch: epoch)
    }

    /// Re-`REQ`s a reconnect's subscriptions in bounded batches, pausing between them.
    ///
    /// A relay budgets requests, and this client holds one subscription per joined channel: sent
    /// as one burst, a large workspace exceeds the budget and the relay refuses the tail of its
    /// own replay. Batching keeps the burst under it. The gate is consulted before every batch
    /// rather than once at the top, because a refusal *during* the replay must slow the batches
    /// still to come — that is the whole difference between pacing and merely starting slowly.
    private func replay(_ ids: [SubscriptionID], epoch: Int) async {
        var index = 0
        while index < ids.count {
            await rateLimitGate.wait()
            // Re-checked after every suspension: a new socket supersedes this replay entirely,
            // and its own `.ready` will re-arm from the top.
            guard readyEpoch == epoch else { return }

            let end = min(index + config.replayBatchSize, ids.count)
            for id in ids[index ..< end] {
                await armSubscription(id, epoch: epoch, resetCloseRetry: true)
            }
            index = end

            if index < ids.count {
                try? await pacingSleep(config.replayInterBatchDelay)
                guard readyEpoch == epoch else { return }
            }
        }
    }

    /// Clears every refusal the dead connection produced.
    private func resetForDisconnect() async {
        for subscription in subscriptions.values {
            resetClosedRetry(subscription)
        }
        await rateLimitGate.reset()
    }

    /// Every registered subscription id, with ``SubscriptionManager/prioritySubscriptionID``
    /// first when it still names a live one.
    ///
    /// The rest keep `Dictionary`'s order. That order is arbitrary, and for them it is
    /// also of no consequence — what mattered was that the subscription a reader is
    /// watching was somewhere in it, taking its chances against every other channel's
    /// re-`REQ`.
    private func armOrder() -> [SubscriptionID] {
        let ids = Array(subscriptions.keys)
        guard let priority = prioritySubscriptionID, subscriptions[priority] != nil else {
            return ids
        }
        return [priority] + ids.filter { $0 != priority }
    }

    /// Sends the `REQ` for a subscription under a readiness epoch, at most once
    /// per epoch. A repeat call for an epoch already served is a no-op, so
    /// registration and the readiness observer cannot double-`REQ` the same
    /// subscription onto one socket.
    func armSubscription(_ id: SubscriptionID, epoch: Int, resetCloseRetry: Bool) async {
        guard let subscription = subscriptions[id], subscription.armedEpoch != epoch else { return }
        subscription.armedEpoch = epoch
        if resetCloseRetry {
            subscription.retriedAfterClose = false
            // A fresh socket is a fresh start: the refusals were the old connection's.
            resetClosedRetry(subscription)
        }
        await sendRequest(for: subscription, epoch: epoch)
    }

    /// Resets a subscription to a fresh backfill and puts its `REQ` on the wire,
    /// choosing the filter by cursor state. A send that fails for lack of a live
    /// socket is expected churn, not an error: the subscription stays registered
    /// and the next `ready` re-arms it.
    func sendRequest(for subscription: Subscription, epoch: Int) async {
        // The single choke point every `REQ` passes through, so the session's rate-limit window
        // is honoured by registration, replay and retry alike rather than by each of them
        // separately. Waiting here suspends this task but not the actor, so frames keep routing.
        await rateLimitGate.wait()
        // Both re-checked after that suspension, which a long window can stretch to minutes: the
        // subscription may have been unsubscribed, and a new socket makes this `REQ` a duplicate
        // of one the new epoch's replay already sent.
        guard subscriptions[subscription.id] === subscription, readyEpoch == epoch else { return }

        subscription.phase = .backfill
        subscription.backfillBuffer.removeAll(keepingCapacity: true)
        subscription.liveBuffer.removeAll(keepingCapacity: true)
        subscription.liveFlushTask?.cancel()
        subscription.liveFlushTask = nil

        let filters = subscription.cursorArmed
            ? replayFilters(for: subscription)
            : subscription.originalFilters
        do {
            try await connection.send(.req(subscriptionID: subscription.id.rawValue, filters: filters))
        } catch {
            // No authenticated socket right now; reconnecting is the connection's
            // job. This subscription re-arms on the next transition into `ready`.
        }
    }

    /// The original filters shifted to resume from the replay cursor: `since` no
    /// earlier than `lastSeen − overlap`, and never earlier than a filter's own
    /// `since`. Applied to every filter in the set. Falls back to the untouched
    /// filters when nothing has been delivered yet.
    private func replayFilters(for subscription: Subscription) -> [Filter] {
        guard let lastSeen = subscription.lastSeen else { return subscription.originalFilters }
        let cursor = lastSeen - config.replayOverlapSeconds
        return subscription.originalFilters.map { filter in
            var copy = filter
            if let existing = filter.since {
                copy.since = max(existing, cursor)
            } else {
                copy.since = cursor
            }
            return copy
        }
    }

    // MARK: - Pre-send validation

    /// Rejects filters a Buzz relay would refuse, before any reach the wire — a
    /// kindless filter, or one asking for a pubkey-gated kind without scoping its
    /// `#p` to exactly the authenticated identity.
    func validate(_ filters: [Filter]) async throws {
        for filter in filters {
            guard let kinds = filter.kinds, !kinds.isEmpty else {
                throw SubscriptionError.kindlessFilter
            }
            guard let gatedKind = kinds.first(where: { Filter.pubkeyGatedKinds.contains($0) }) else {
                continue
            }
            let pubkey = try await authenticatedPubkeyHex()
            guard Set(filter.tagQueries["p"] ?? []) == [pubkey] else {
                throw SubscriptionError.pubkeyScopeRequired(gatedKind)
            }
        }
    }

    private func authenticatedPubkeyHex() async throws -> String {
        if let cachedPubkeyHex { return cachedPubkeyHex }
        let hex = try await signer.publicKey().hex
        cachedPubkeyHex = hex
        return hex
    }
}
