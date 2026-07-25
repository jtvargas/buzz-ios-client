import Foundation
import NostrCore
import os

/// The standing per-channel content subscriptions — the live path for all
/// channel-scoped traffic.
///
/// The relay scopes a REQ by its filters: a REQ is channel-scoped only when *every*
/// filter carries a `#h` tag query, and a channel-scoped event never fans out to a
/// global (`#h`-less) subscription. So the engine keeps one standing subscription
/// per joined channel, each a *single* `#h`-scoped filter — never multiplexed with
/// any global filter, which would demote the whole REQ to global and starve it of
/// the very events it exists to receive.
///
/// # Lifecycle
///
/// The set is *grown* on every `.ready` to cover the discovered/known channel list
/// (``ensureChannelSubscriptions(_:)``) and on `memberAdded`. It shrinks only on an
/// explicit departure — `memberRemoved`/leave (``unsubscribeChannelContent(_:)``) —
/// or a relay `CLOSE` (``dropClosedChannelSubscription(_:)``).
///
/// Discovery is deliberately **add-only**: a channel is *not* dropped merely because a
/// single discovery pass failed to echo it. A relay can serve partial group state on
/// any given pass, and unsubscribing on a transient miss would tear down a live
/// subscription and re-open it next pass — a CLOSE, a re-REQ, and a re-backfill, with
/// a window of dropped live events in between. Removal therefore tracks the
/// authoritative membership signal (the `#p`-scoped 44101 notification) and the
/// relay's own CLOSE, never a discovery gap.
///
/// The ``SubscriptionManager`` keeps each registered subscription alive across
/// reconnects and re-arms it on the next `.ready`, so this layer only decides *which*
/// channels are subscribed, never re-registers on reconnect.
extension SyncEngine {
    /// The live content filter for one channel: the Buzz message and overlay kinds
    /// plus channel-scoped typing, `#h`-scoped and reaching back a small window so the
    /// connect gap drops nothing. Deep history is the window reconcile's job.
    ///
    /// Kinds, in wire order: channel message (9), rich message (40002), message edit
    /// (40003), reaction (7), deletion (5), group delete event (9005), typing (20002)
    /// — the measured live-delivering shape. This is a single filter by design (see
    /// the type doc): one `#h` filter per REQ.
    func contentFilter(forChannel channel: String) -> Filter {
        Filter(
            kinds: [
                .channelMessage, .richMessage, .messageEdit,
                .reaction, .deletion, .groupDeleteEvent, .typing,
            ],
            since: Int64(now().timeIntervalSince1970) - Int64(config.liveSinceWindow),
            tagQueries: ["h": [channel]]
        )
    }

    // MARK: - Set growth (discovery)

    /// Ensures a standing content subscription exists for every channel in `desired`,
    /// registering the ones not yet subscribed. Add-only and idempotent (see the type
    /// doc for why discovery never removes): a channel already subscribed is left
    /// untouched, so a reconnect's rediscovery does not churn the wire.
    ///
    /// Called on every discovery pass with the discovered ∪ known channel set, the
    /// same set the head reconcile iterates.
    func ensureChannelSubscriptions(_ desired: Set<String>) async {
        for channel in desired.subtracting(Set(channelContentSubscriptions.keys)) {
            await subscribeChannelContent(channel)
        }
    }

    // MARK: - Single-channel add / drop

    /// Registers the standing content subscription for `channel`, if one is not
    /// already open, and returns its id. Idempotent: a second call returns the
    /// existing id without a second `REQ`. Registration tolerates a not-yet-ready
    /// socket — the ``SubscriptionManager`` arms it on the next `.ready` and keeps it
    /// alive across reconnects.
    @discardableResult
    func subscribeChannelContent(_ channel: String) async -> SubscriptionID? {
        if let existing = channelContentSubscriptions[channel] { return existing }
        // A single `#h` filter per REQ — never multiplexed with a global filter, or
        // the relay would demote the whole REQ to global and it would receive no
        // channel traffic at all.
        guard let id = try? await subscriptions.register(
            filters: [contentFilter(forChannel: channel)], sink: self
        ) else { return nil }
        channelContentSubscriptions[channel] = id
        return id
    }

    /// Drops the standing content subscription for `channel` with a `CLOSE`. A no-op
    /// when none is open.
    func unsubscribeChannelContent(_ channel: String) async {
        guard let id = channelContentSubscriptions.removeValue(forKey: channel) else { return }
        await subscriptions.unsubscribe(id)
    }

    // MARK: - Relay-initiated close

    /// Handles a relay `CLOSE` of a subscription: if it is one of the standing
    /// per-channel content subscriptions, drop it from the set and log. The manager
    /// has already removed it from its own table, so there is nothing to unsubscribe;
    /// a later discovery pass re-registers the channel if it is still desired.
    /// Returns the channel whose subscription was dropped, or `nil` if the id was not
    /// a channel content sub (e.g. the global REQ, which reconnect re-registers).
    @discardableResult
    func dropClosedChannelSubscription(_ id: SubscriptionID) -> String? {
        guard let channel = channelContentSubscriptions.first(where: { $0.value == id })?.key else {
            return nil
        }
        channelContentSubscriptions.removeValue(forKey: channel)
        Self.channelSubLog.notice(
            "relay CLOSED per-channel content sub for channel \(channel, privacy: .public); dropped"
        )
        return channel
    }

    /// Logger for the standing-subscription lifecycle. Scoped to its own category so
    /// a relay CLOSE of a channel sub is observable without adding a general logging
    /// dependency to the sync core.
    static let channelSubLog = Logger(subsystem: "BuzzKit", category: "SyncEngine.channelSubscriptions")
}
