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
        guard transitionedToReady else { return }

        readyEpoch += 1
        let epoch = readyEpoch
        // Snapshot the ids: `armSubscription` awaits a send, during which a
        // reentrant register or unsubscribe may mutate the table.
        for id in Array(subscriptions.keys) {
            await armSubscription(id, epoch: epoch, resetCloseRetry: true)
        }
    }

    /// Sends the `REQ` for a subscription under a readiness epoch, at most once
    /// per epoch. A repeat call for an epoch already served is a no-op, so
    /// registration and the readiness observer cannot double-`REQ` the same
    /// subscription onto one socket.
    func armSubscription(_ id: SubscriptionID, epoch: Int, resetCloseRetry: Bool) async {
        guard let subscription = subscriptions[id], subscription.armedEpoch != epoch else { return }
        subscription.armedEpoch = epoch
        if resetCloseRetry { subscription.retriedAfterClose = false }
        await sendRequest(for: subscription)
    }

    /// Resets a subscription to a fresh backfill and puts its `REQ` on the wire,
    /// choosing the filter by cursor state. A send that fails for lack of a live
    /// socket is expected churn, not an error: the subscription stays registered
    /// and the next `ready` re-arms it.
    func sendRequest(for subscription: Subscription) async {
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
