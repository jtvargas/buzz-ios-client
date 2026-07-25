import Foundation
import NostrCore

/// Deprecated per-channel typing subscription shims.
///
/// Typing (kind 20002) is now carried by the standing per-channel content
/// subscription (``contentFilter(forChannel:)`` includes 20002), whose lifecycle the
/// engine owns through discovery and membership — not the view. These two methods
/// remain only because the app still drives them through its `ChannelTypingControlling`
/// seam; they are thin shims over the standing subscription, kept so the app layer
/// can be migrated off them in a follow-up rather than in this change.
///
/// - ``openChannelTyping(_:)`` ensures the channel's standing content subscription
///   exists (so a view that appears before discovery has registered the channel still
///   gets live typing and messages) and returns its id.
/// - ``closeChannelTyping(_:)`` is a no-op: the standing subscription persists for the
///   channel's membership, independent of any one view's lifetime.
public extension SyncEngine {
    /// Ensures the standing content subscription for `channel` exists and returns its
    /// id. Idempotent. Subsumed by the per-channel content subscription; retained as a
    /// shim for the app's `ChannelTypingControlling` seam.
    @discardableResult
    func openChannelTyping(_ channel: String) async throws -> SubscriptionID {
        if let existing = channelContentSubscriptions[channel] { return existing }
        let id = try await subscriptions.register(
            filters: [contentFilter(forChannel: channel)], sink: self
        )
        channelContentSubscriptions[channel] = id
        return id
    }

    /// No-op. The standing content subscription's lifecycle is owned by discovery and
    /// membership, so a view disappearing does not tear it down. Retained so the app
    /// can call it unconditionally until it is migrated off the typing seam.
    func closeChannelTyping(_: String) async {}
}
