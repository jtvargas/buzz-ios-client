import Foundation
import NostrCore

/// Per-channel typing subscriptions.
///
/// Typing indicators (kind 20002) carry an `["h", channel]` tag, and the relay
/// fans an h-tagged ephemeral out **only** to subscriptions whose filter names that
/// channel with a `#h` tag query — measured against the production relay. The
/// engine's global content filter is kinds-only (no `#h`), so it receives presence
/// (channel-less) but never typing. To see a peer's typing, a channel that is on
/// screen registers a dedicated `kinds:[20002] + #h:[channel]` subscription routed
/// to the same engine sink; the sink already diverts verified ephemerals into
/// ``PresenceStore`` keyed `(channel, pubkey)` (the step-2 chain), so nothing else
/// has to change. This mirrors upstream Buzz's per-channel typing subscription.
public extension SyncEngine {
    /// Opens the typing subscription for `channel`, if one is not already open.
    ///
    /// Idempotent: a second call for a channel already subscribed returns the
    /// existing id without a second `REQ`. Registration tolerates a not-yet-ready
    /// socket — the ``SubscriptionManager`` keeps it registered and arms it on the
    /// next `.ready`, and keeps it alive across reconnects — so a view may open it
    /// the instant it appears without waiting on the connection.
    @discardableResult
    func openChannelTyping(_ channel: String) async throws -> SubscriptionID {
        if let existing = channelTypingSubscriptions[channel] { return existing }
        let id = try await subscriptions.register(
            filters: [Filter(kinds: [.typing], tagQueries: ["h": [channel]])],
            sink: self
        )
        channelTypingSubscriptions[channel] = id
        return id
    }

    /// Closes the typing subscription for `channel`. A no-op when none is open, so a
    /// view can call it unconditionally as it disappears.
    func closeChannelTyping(_ channel: String) async {
        guard let id = channelTypingSubscriptions.removeValue(forKey: channel) else { return }
        await subscriptions.unsubscribe(id)
    }
}
