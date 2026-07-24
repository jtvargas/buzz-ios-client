import Foundation

/// Inbound frame routing and the batched, phase-marked delivery to sinks.
extension SubscriptionManager {
    /// Routes one frame the connection surfaced for a consumer-owned
    /// subscription. Internal so a test can drive batching directly, frame by
    /// frame, without standing up a socket.
    func route(_ frame: RelayInbound) async {
        switch frame {
        case let .event(subscriptionID, event):
            await handleEvent(event, for: SubscriptionID(subscriptionID))
        case let .endOfStoredEvents(subscriptionID):
            await handleEndOfStoredEvents(for: SubscriptionID(subscriptionID))
        case let .closed(subscriptionID, reason):
            await handleClosed(SubscriptionID(subscriptionID), reason: reason)
        }
    }

    private func handleEvent(_ event: NostrEvent, for id: SubscriptionID) async {
        // A frame for a subscription we no longer hold — unsubscribed, or closed
        // and removed — has nowhere to go. Dropping it is correct.
        guard let subscription = subscriptions[id] else { return }
        advanceHighWaterMark(subscription, with: event)

        switch subscription.phase {
        case .backfill:
            subscription.backfillBuffer.append(event)
            if subscription.backfillBuffer.count >= config.batchSize {
                await flushBackfill(subscription)
            }
        case .live:
            subscription.liveBuffer.append(event)
            if subscription.liveBuffer.count >= config.batchSize {
                // A live burst as large as a whole batch: flush it at once rather
                // than hold it for the tick, which bounds buffered memory.
                subscription.liveFlushTask?.cancel()
                subscription.liveFlushTask = nil
                await flushLive(subscription)
            } else {
                scheduleLiveFlush(id)
            }
        }
    }

    private func handleEndOfStoredEvents(for id: SubscriptionID) async {
        guard let subscription = subscriptions[id] else { return }

        // Flush the remaining backfill first, then mark the boundary: the sink
        // must see every stored event before it is told the store is caught up.
        if !subscription.backfillBuffer.isEmpty {
            await flushBackfill(subscription)
            guard subscriptions[id] != nil else { return } // torn down mid-flush
        }

        subscription.phase = .live
        // The first EOSE proves a complete replay was observed, which is the only
        // safe moment to arm the high-water mark as a reconnect cursor.
        subscription.cursorArmed = true
        subscription.retriedAfterClose = false
        await subscription.sink.endOfStoredEvents(subscription: id)
    }

    private func handleClosed(_ id: SubscriptionID, reason: OKReason) async {
        guard let subscription = subscriptions[id] else { return }

        switch reason.disposition {
        case .reauthThenRetry where !subscription.retriedAfterClose:
            // Consistent with the connection's one-shot handling of an
            // `auth-required` CLOSED: re-open once. The re-`REQ` rides the
            // connection's own auth gate; a second such close gives up below.
            subscription.retriedAfterClose = true
            await sendRequest(for: subscription)
        default:
            subscriptions.removeValue(forKey: id)
            subscription.liveFlushTask?.cancel()
            await subscription.sink.subscriptionClosed(subscription: id, error: .closedByRelay(reason))
        }
    }

    // MARK: - High-water mark and flushing

    private func advanceHighWaterMark(_ subscription: Subscription, with event: NostrEvent) {
        if let lastSeen = subscription.lastSeen {
            subscription.lastSeen = max(lastSeen, event.createdAt)
        } else {
            subscription.lastSeen = event.createdAt
        }
    }

    /// Delivers the buffered backfill as one `.backfill` batch and clears it. The
    /// buffer is read and cleared before the `await`, so an event that arrives
    /// while the sink is working lands in the next batch, never this one.
    private func flushBackfill(_ subscription: Subscription) async {
        guard !subscription.backfillBuffer.isEmpty else { return }
        let batch = subscription.backfillBuffer
        subscription.backfillBuffer.removeAll(keepingCapacity: true)
        await subscription.sink.ingest(batch: batch, subscription: subscription.id, phase: .backfill)
    }

    /// Delivers the buffered live events as one `.live` batch and clears it. The
    /// caller owns cancelling any pending tick.
    private func flushLive(_ subscription: Subscription) async {
        guard !subscription.liveBuffer.isEmpty else { return }
        let batch = subscription.liveBuffer
        subscription.liveBuffer.removeAll(keepingCapacity: true)
        await subscription.sink.ingest(batch: batch, subscription: subscription.id, phase: .live)
    }

    /// Arms a single coalescing tick for a live subscription, unless one is
    /// already pending. Events arriving during the tick join the same flush, so a
    /// small live burst becomes one delivery rather than several.
    private func scheduleLiveFlush(_ id: SubscriptionID) {
        guard let subscription = subscriptions[id], subscription.liveFlushTask == nil else { return }
        let sleep = liveFlushSleep
        let interval = config.liveFlushInterval
        subscription.liveFlushTask = Task { [weak self] in
            do {
                try await sleep(interval)
            } catch {
                return // cancelled: a flood flush already drained the buffer
            }
            await self?.fireLiveFlush(id)
        }
    }

    private func fireLiveFlush(_ id: SubscriptionID) async {
        guard let subscription = subscriptions[id] else { return }
        subscription.liveFlushTask = nil
        await flushLive(subscription)
    }
}
