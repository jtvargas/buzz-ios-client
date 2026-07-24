import Foundation

/// A subscription frame the connection received and did not consume itself.
///
/// ``RelayConnection`` handles the frames that are its own business — NIP-42
/// challenges, auth verdicts, publish acknowledgements, and the frames belonging
/// to one-shot queries it is running. Everything else is a subscription frame for
/// a consumer above it, and is surfaced through this type on
/// ``RelayConnection/inbound()``.
///
/// This is the minimal seam the Phase 1 subscription manager (build-order step 8)
/// builds on: it owns the live subscriptions, so it — not the connection — routes
/// these to sinks, arms EOSE-gated replay cursors, and re-subscribes after a
/// reconnect. Keeping the connection ignorant of live-subscription bookkeeping is
/// what lets each layer be tested on its own.
public enum RelayInbound: Sendable, Equatable {
    /// An event delivered for a subscription the consumer owns.
    case event(subscriptionID: String, event: NostrEvent)
    /// The relay finished replaying stored events for a subscription; everything
    /// after is live.
    case endOfStoredEvents(subscriptionID: String)
    /// The relay closed a subscription, with its reason already classified. A
    /// consumer decides whether to re-open based on the ``OKReason`` disposition.
    case closed(subscriptionID: String, reason: OKReason)
}
