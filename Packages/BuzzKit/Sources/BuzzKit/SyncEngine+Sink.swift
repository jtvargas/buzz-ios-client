import Foundation
import NostrCore

/// The ``EventSink`` conformance: the choke point every subscription frame flows
/// through on its way into the store, the presence divert, and the watermark
/// advance.
extension SyncEngine: EventSink {
    /// Ingests one batch from the multiplexed live subscription.
    ///
    /// Everything goes through ``BuzzEventStore``'s single verification choke point.
    /// The watermark advances only for channels already `synced`, and only on the
    /// live phase (rule 4): a backfill or an unsynced channel ingests but holds its
    /// watermark. Verified ephemerals the store diverts are forwarded to the
    /// presence store, and a membership add/remove triggers a re-discovery and head
    /// reconcile of that channel.
    public func ingest(batch: [NostrEvent], subscription _: SubscriptionID, phase: IngestPhase) async {
        let advancing = phase == .live ? syncedChannels() : []
        let result = try? await store.ingest(batch: batch, phase: phase, advancingWatermarksIn: advancing)

        if let result, !result.ephemeral.isEmpty {
            await presence.apply(result.ephemeral)
        }

        // A membership change is group state that does not ride the live fan-out, so
        // its arrival is the signal to re-fetch that channel's head and roster.
        var touched: Set<String> = []
        for event in batch where event.kind == .memberAdded || event.kind == .memberRemoved {
            if let channel = event.groupID { touched.insert(channel) }
        }
        for channel in touched {
            scheduleChannelReconcile(channel)
        }
    }

    /// The live subscription caught up. Reconcile is driven independently on every
    /// `.ready`, so the boundary needs no extra work here; the hook is kept for the
    /// sink contract and a future backfill-drained optimization.
    public func endOfStoredEvents(subscription _: SubscriptionID) async {}

    /// The relay closed the multiplexed live subscription with a terminal reason.
    /// The connection layer owns reconnect and re-auth; a fresh `.ready`
    /// re-registers the subscription through the manager, so nothing is torn down
    /// here.
    public func subscriptionClosed(subscription _: SubscriptionID, error _: SubscriptionError) async {}

    // MARK: - Membership-triggered reconcile

    /// Schedules a re-discovery and head reconcile of a channel whose membership
    /// just changed. Best-effort and only while running; the reconcile is
    /// idempotent, so a redundant trigger costs a deduped refetch.
    func scheduleChannelReconcile(_ channel: String) {
        guard state == .running else { return }
        let generation = readyGeneration
        Task { [weak self] in
            await self?.rediscoverAndReconcile(channel, generation: generation)
        }
    }
}
