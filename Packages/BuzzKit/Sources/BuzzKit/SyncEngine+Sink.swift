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

        // Read-state blobs (`kind:30078`) are stored in the log like any event but
        // carry NIP-44 ciphertext the keyless projector cannot read, so the engine —
        // which holds the identity — decrypts the freshly-inserted ones and applies
        // them to the precious `read_state` table. Only newly-inserted events are
        // decrypted: a reconnect resends the latest replaceable blob, and re-decrypting
        // a duplicate every reconnect would be wasted work for an idempotent apply.
        if let result, !result.inserted.isEmpty {
            let insertedIDs = Set(result.inserted)
            let readStateEvents = batch.filter { $0.kind == .readState && insertedIDs.contains($0.id) }
            if !readStateEvents.isEmpty {
                await applyIncomingReadState(readStateEvents)
            }

            // A message is the end of its author's typing where it landed. Only the
            // newly-inserted ones: a reconnect replays messages already in the log, and
            // re-clearing on those would silence an indicator that has since started
            // again for real. See ``PresenceStore/messagesArrived(_:)``.
            //
            // Both message kinds, not just kind 9: a rich message is a message somebody
            // finished writing too, and a client that publishes them would otherwise
            // leave its typing to lapse on the clock. An *edit* is deliberately not here
            // — revising a message says nothing about whether a new one is being written.
            let messages = batch.filter {
                ($0.kind == .channelMessage || $0.kind == .richMessage) && insertedIDs.contains($0.id)
            }
            if !messages.isEmpty {
                await presence.messagesArrived(messages)
            }
        }

        // A membership change is group state that does not ride the live fan-out, so
        // its arrival is the signal to reconcile the channel's standing content
        // subscription and (on add) re-fetch its head and roster. These notifications
        // are `#p`-scoped to self, so an add means "you joined channel X" and a remove
        // means "you left / were removed from X".
        //
        // Collapse to the single most-recent membership fact per channel by the
        // `(created_at, id)` total order. One batch can carry a leave *and* a later
        // rejoin (or vice versa) for the same channel — exactly what a reconnect replay
        // of offline membership changes produces — and only the newest event states the
        // current fact. Acting on per-kind sets with removes applied last would end a
        // leave-then-rejoin unsubscribed and silently live-dead until the next `.ready`.
        var latest: [String: NostrEvent] = [:]
        for event in batch {
            guard event.kind == .memberAdded || event.kind == .memberRemoved,
                  let channel = event.groupID else { continue }
            let cursor = WindowCursor(createdAt: event.createdAt, id: event.id)
            if let current = latest[channel],
               WindowCursor(createdAt: current.createdAt, id: current.id) >= cursor {
                continue
            }
            latest[channel] = event
        }
        for (channel, event) in latest where event.kind == .memberAdded {
            // Joined (net): start the standing content sub at once so live traffic
            // flows, then reconcile the head/roster the membership change implies.
            _ = try? await subscribeChannelContent(channel)
            scheduleChannelReconcile(channel)
        }
        for (channel, event) in latest where event.kind == .memberRemoved {
            // Left (net): drop the standing content sub — the relay would refuse
            // further channel-scoped traffic to a non-member anyway.
            await unsubscribeChannelContent(channel)
        }
    }

    /// The live subscription caught up. Reconcile is driven independently on every
    /// `.ready`, so the boundary needs no extra work here; the hook is kept for the
    /// sink contract and a future backfill-drained optimization.
    public func endOfStoredEvents(subscription _: SubscriptionID) async {}

    /// The relay closed a subscription with a terminal reason.
    ///
    /// If it is one of the standing per-channel content subscriptions, drop it from
    /// the set and log (``dropClosedChannelSubscription(_:)``); a later discovery pass
    /// re-registers the channel if it is still desired. If it is the global REQ, the
    /// connection layer owns reconnect and re-auth and a fresh `.ready` re-registers
    /// it through the manager, so nothing is torn down here.
    public func subscriptionClosed(subscription id: SubscriptionID, error _: SubscriptionError) async {
        dropClosedChannelSubscription(id)
    }

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
