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
/// The set is reconciled on every authoritative directory pass to
/// ``liveChannels(joined:)`` — the channels whose relay-signed roster names this
/// identity, plus the one on screen — and grown on `memberAdded`,
/// ``joinChannel(_:onProgress:)`` and ``setActiveChannel(_:)``. It shrinks on that
/// reconcile, on an explicit departure (`memberRemoved`/leave,
/// ``unsubscribeChannelContent(_:)``), or a relay `CLOSE`
/// (``dropClosedChannelSubscription(_:)``).
///
/// Removal is deliberately never driven by **discovery**: a channel is not dropped
/// because a single discovery pass failed to echo it. A relay can serve partial group
/// state on any given pass, and unsubscribing on a transient miss would tear down a live
/// subscription and re-open it next pass — a CLOSE, a re-REQ, and a re-backfill, with a
/// window of dropped live events in between. It is driven instead by the durable
/// `channel_member` projection, which a *newer* kind 39002 replaces and a missing one
/// cannot narrow, and by the authoritative membership signal (the `#p`-scoped 44101) and
/// the relay's own CLOSE.
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
    /// (40003), system message (40099), reaction (7), deletion (5), group delete event
    /// (9005), typing (20002), thread summary (39005) — the measured live-delivering
    /// shape. This is a single filter by design (see the type doc): one `#h` filter per
    /// REQ.
    ///
    /// The thread summary is the relay telling a subscriber that a message's reply
    /// tally moved, without anybody having to fetch the replies to find out. It pushes
    /// a freshly signed `kind:39005` on every reply insert *and* on every deletion, and
    /// tags it with the channel — so it was always addressed to this subscription, and
    /// this filter's kind list was the only reason it never arrived. Leaving it out
    /// meant a reply tally could only move by fetching the thread, which is what made a
    /// message advertise its replies only once you pressed it.
    ///
    /// It is a row in no timeline: every read that draws messages selects an explicit
    /// kind (`e.kind = :kind`, plus the notice kind), so a 39005 in the log is reachable
    /// only through the `thread_summary` projection it feeds.
    ///
    /// The system message is the relay narrating the channel to itself — somebody
    /// joined, was added, left. It is `#h`-scoped like a message, so it belongs here
    /// and not among the global filters: what *is* global is the `#p`-scoped
    /// 44100/44101 pair, and those only ever speak about the local identity's own
    /// membership, which is why nothing has ever shown a reader that somebody else
    /// arrived.
    func contentFilter(forChannel channel: String) -> Filter {
        Filter(
            kinds: [
                .channelMessage, .richMessage, .messageEdit, .systemMessage,
                .reaction, .deletion, .groupDeleteEvent, .typing, .threadSummary,
                // A huddle starting and ending, which the timeline draws as notices.
                // 48101/48102 are deliberately not requested: nothing renders a
                // participant arriving, and subscribing to an event no surface reads is
                // bandwidth and storage spent to no end.
                .huddleStarted, .huddleEnded,
                // The two things that can ask a human for a decision. Added for the
                // Activity tab's Action chip, which listed them in its read while nothing
                // ever fetched them — so the chip could not fill, rather than merely having
                // nothing to show. Both are channel-scoped in the relay's own feed query
                // (`crates/buzz-db/src/feed.rs:191`) and both ride stream subscriptions in
                // the ACP harness, so they belong on this filter beside kind 9.
                .workflowApprovalRequested, .streamReminder,
            ],
            since: Int64(now().timeIntervalSince1970) - Int64(config.liveSinceWindow),
            tagQueries: ["h": [channel]]
        )
    }

    // MARK: - Set growth (discovery)

    /// Ensures a standing content subscription exists for every channel in `desired`,
    /// registering the ones not yet subscribed. Add-only and idempotent (see the type
    /// doc for why discovery never removes): a channel already subscribed is left
    /// untouched, so a reconnect's rediscovery does not churn the wire. Best-effort —
    /// a filter the relay would refuse is skipped rather than aborting the pass.
    ///
    /// Called on every authoritative pass with ``liveChannels(joined:)``, the same set
    /// the head reconcile iterates.
    func ensureChannelSubscriptions(_ desired: Set<String>) async {
        let generation = readyGeneration
        var missing = desired.subtracting(Set(channelContentSubscriptions.keys))
        while isCurrent(generation), let channel = recentChannelOrder(among: missing).first {
            missing.remove(channel)
            _ = try? await subscribeChannelContent(channel, deferArming: channel != activeChannel)
        }
    }

    /// The channels that earn a standing subscription and a head reconcile at rest:
    /// **real membership**, plus whatever conversation is on screen.
    ///
    /// # Why membership rather than what the sidebar draws
    ///
    /// The relay serves every open channel to any key, so `channel_access.state` reaches
    /// `.active` for channels nobody has joined — by design, since a reader may write to
    /// an open channel without being on its roster. Scoping the resting cost to that set
    /// meant every open channel on the relay bought a standing `#h` REQ and a head
    /// reconcile out of the same 50 REQ / 5 s budget as the channels the reader actually
    /// reads. `joined` comes from `channel_member` instead — a projection only a newer
    /// kind 39002 can narrow, which is what makes it safe to *remove* against.
    ///
    /// # Why the active channel is in here
    ///
    /// Opening a conversation subscribes and refreshes its head on demand. Keeping
    /// the active channel here lets directory reconciliation retain that subscription
    /// even when the reader has not joined the open channel.
    func liveChannels(joined: Set<String>) -> Set<String> {
        guard let activeChannel else { return joined }
        return joined.union([activeChannel])
    }

    /// Reconciles to the authoritative active-membership set exactly. Cached
    /// history remains in SQLite; only live delivery follows membership.
    func reconcileChannelSubscriptions(_ desired: Set<String>) async {
        let current = Set(channelContentSubscriptions.keys)
        for channel in current.subtracting(desired) {
            await unsubscribeChannelContent(channel)
            channelStates.removeValue(forKey: channel)
        }
        await ensureChannelSubscriptions(desired)
    }

    // MARK: - Single-channel add / drop

    /// Registers the standing content subscription for `channel`, if one is not
    /// already open, and returns its id. Idempotent: a second call returns the
    /// existing id without a second `REQ`. Registration tolerates a not-yet-ready
    /// socket — the ``SubscriptionManager`` arms it on the next `.ready` and keeps it
    /// alive across reconnects.
    ///
    /// The single registration primitive: both the discovery pass and the
    /// ``openChannelTyping(_:)`` shim funnel through here, so the reentrancy re-check
    /// below covers every caller.
    @discardableResult
    func subscribeChannelContent(_ channel: String, deferArming: Bool = false) async throws -> SubscriptionID {
        if let existing = channelContentSubscriptions[channel] { return existing }
        // A single `#h` filter per REQ — never multiplexed with a global filter, or
        // the relay would demote the whole REQ to global and it would receive no
        // channel traffic at all.
        let id = try await subscriptions.register(
            filters: [contentFilter(forChannel: channel)], sink: self, deferArming: deferArming
        )
        // A concurrent caller may have registered this same channel while we awaited
        // the REQ above (actor reentrancy across the await). Keep the winner already in
        // the map and drop this duplicate, so we never leak a second standing sub that
        // would only be cleaned up at ``stop()``.
        if let winner = channelContentSubscriptions[channel] {
            await subscriptions.unsubscribe(id)
            return winner
        }
        channelContentSubscriptions[channel] = id
        // A conversation can be recorded before discovery has registered its channel.
        // Rebuild the full priority list now so a newly registered recent channel takes its
        // intended place without waiting for its view to report itself a second time.
        await updateSubscriptionPriorities()
        return id
    }

    // MARK: - Re-arm priority

    /// Promotes the visible conversation for replay and catch-up, registers its
    /// live subscription if needed, and requests a fresh head on navigation.
    /// Recent successful heads are shared for five seconds to coalesce rapid returns.
    /// The head job is owned by the engine and never delays screen presentation.
    public func setActiveChannel(_ channel: String?) async {
        await setActiveDestination(channel.map(RecentConversationDestination.channel))
    }

    /// Reports the exact thread on screen. Its channel remains the live-subscription
    /// priority, while its root earns a direct reply query on the next fresh socket before
    /// general channel reconciliation.
    public func setActiveThread(channel: String, root: String) async {
        guard !channel.isEmpty, !root.isEmpty else { return }
        await setActiveDestination(.thread(channelID: channel, rootID: root))
    }

    private func setActiveDestination(_ destination: RecentConversationDestination?) async {
        activeChannel = destination?.channelID
        if let destination {
            recentConversationDestinations = RecentConversationDestination.recording(
                destination,
                in: recentConversationDestinations
            )
        }

        await updateRecoveryPriorities()
        if let channel = destination?.channelID { refreshVisibleChannel(channel) }

        if let channel = destination?.channelID, channelContentSubscriptions[channel] == nil {
            _ = try? await subscribeChannelContent(channel)
        }
        await updateSubscriptionPriorities()
        if destination != nil, let identity = selfPubkeyHex {
            try? await store.saveRecentConversationDestinations(recentConversationDestinations, identity: identity)
        }
    }

    /// Channel ids in mixed-destination MRU order, de-duplicated by channel, followed by
    /// every remaining candidate in stable order.
    func recentChannelOrder(among candidates: Set<String>) -> [String] {
        var seen: Set<String> = []
        let recent = recentConversationDestinations.compactMap { destination -> String? in
            let channel = destination.channelID
            guard candidates.contains(channel), seen.insert(channel).inserted else { return nil }
            return channel
        }
        return recent + candidates.subtracting(seen).sorted()
    }

    private func updateSubscriptionPriorities() async {
        let channelIDs = recentChannelOrder(among: Set(channelContentSubscriptions.keys))
        await subscriptions.prioritise(channelIDs.compactMap { channelContentSubscriptions[$0] })
    }

    /// Drops the standing content subscription for `channel` with a `CLOSE`. A no-op
    /// when none is open.
    func unsubscribeChannelContent(_ channel: String) async {
        cancelChannelRecovery(channel)
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
