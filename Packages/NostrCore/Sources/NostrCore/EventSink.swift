import Foundation

/// The destination a ``SubscriptionManager`` delivers subscription output to.
///
/// This is the seam between the network layer and whatever persists or displays
/// events — in Phase 2, BuzzKit's event store. It is deliberately **batch
/// shaped**: every delivery hands over an array, never a single event. A relay
/// answers a `REQ` by replaying its stored history newest-first, which for a
/// busy channel is hundreds of events back to back; delivering those one at a
/// time would cost one hop across the store's isolation — and, for a persistent
/// store, potentially one write transaction — per event. Batching collapses a
/// backfill into a handful of calls, and lets the store verify signatures in
/// parallel and write once per batch.
///
/// Each batch is tagged with its ``IngestPhase`` so the store can tell a bounded
/// catch-up from the live trickle, and ``endOfStoredEvents(subscription:)`` marks
/// the boundary between them. A subscription that the relay takes away is
/// reported through ``subscriptionClosed(subscription:error:)`` with the reason
/// already classified.
///
/// All methods are `async` so a store that is an actor conforms without extra
/// bridging, and `Sendable` so a sink can be handed across the manager's actor
/// boundary.
public protocol EventSink: Sendable {
    /// Delivers a batch of events for one subscription, all belonging to the
    /// given phase. Events within a batch are in the order the relay sent them.
    func ingest(batch: [NostrEvent], subscription: SubscriptionID, phase: IngestPhase) async

    /// Signals that the relay has finished replaying stored events for the
    /// subscription. Any buffered backfill has already been delivered through
    /// ``ingest(batch:subscription:phase:)`` before this is called; everything
    /// after it arrives in the ``IngestPhase/live`` phase.
    func endOfStoredEvents(subscription: SubscriptionID) async

    /// Reports that the subscription has ended because the relay closed it and it
    /// will not be re-opened, carrying the classified reason.
    func subscriptionClosed(subscription: SubscriptionID, error: SubscriptionError) async
}
