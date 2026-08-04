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
        for channel in desired.subtracting(Set(channelContentSubscriptions.keys)) {
            _ = try? await subscribeChannelContent(channel)
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
    /// Nothing else would give it live traffic. Opening a conversation registers no
    /// subscription and issues no window request of its own: ``setActiveChannel(_:)`` was
    /// priority-only, and `ChannelTimelineModel` is purely the read side. So a channel the
    /// reader can still reach from the sidebar but is not a member of — every open channel
    /// they have not joined, until a browse surface takes over the sidebar — would render
    /// its cached history and then never move again. Including it here, and subscribing on
    /// demand in ``setActiveChannel(_:)``, means the resting cost is membership while
    /// nothing visible can freeze.
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
    func subscribeChannelContent(_ channel: String) async throws -> SubscriptionID {
        if let existing = channelContentSubscriptions[channel] { return existing }
        // A single `#h` filter per REQ — never multiplexed with a global filter, or
        // the relay would demote the whole REQ to global and it would receive no
        // channel traffic at all.
        let id = try await subscriptions.register(
            filters: [contentFilter(forChannel: channel)], sink: self
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
        // A conversation can be on screen before discovery has registered its channel —
        // opening one is itself a route into this method. Claim the re-arm priority now
        // rather than waiting for the next ``setActiveChannel(_:)``, which for a channel
        // already open would never come.
        if channel == activeChannel {
            await subscriptions.prioritise(id)
        }
        return id
    }

    // MARK: - Re-arm priority

    /// Reports which channel the reader has on screen, so a reconnect restores that
    /// channel's live traffic before every other channel's.
    ///
    /// A reconnect re-`REQ`s every standing subscription and the engine keeps one per
    /// joined channel, so without a stated preference the open conversation took its
    /// turn in an arbitrary order — on a busy account, potentially last. This names it,
    /// and the ``SubscriptionManager`` arms it first.
    ///
    /// Ordering only: membership, filters and delivery are all untouched, and there is no
    /// obligation to clear it when the conversation closes. Leaving the last-read channel
    /// prioritised is the better resting state anyway: it is where the reader most likely
    /// returns.
    ///
    /// # Why it also subscribes
    ///
    /// Because nothing else does. The resting subscription set is real membership
    /// (``liveChannels(joined:)``), and a reader can still open a channel they are not a
    /// member of — every open channel on the relay is reachable until a browse surface
    /// takes the sidebar over. Naming one used to be a no-op against an absent
    /// subscription, and the screen has no relay path of its own: `ChannelTimelineModel`
    /// consumes ``DatabaseSignal`` and re-reads the store, and `prefetchThreads(in:)`
    /// fetches replies to threads already held. So such a channel drew its cached history
    /// and then froze — no live messages, no fresh head.
    ///
    /// This registers the standing subscription if one is missing and kicks the head
    /// reconcile that fills the gap, which is the entire relay side of opening a channel.
    /// The reconcile is **detached rather than awaited**, for the same reason
    /// ``assembleNotices(_:generation:)`` is: a screen presenting must not wait on a
    /// window round trip. It is generation-guarded, so a reconnect mid-flight abandons it
    /// and the fresh `.ready` reconciles the channel itself — the active channel is in the
    /// desired set of every pass.
    ///
    /// Idempotent and cheap on the common path: a channel already subscribed — every
    /// channel the reader is a member of — takes the priority call and nothing else.
    public func setActiveChannel(_ channel: String?) async {
        activeChannel = channel
        if let channel, channelContentSubscriptions[channel] == nil {
            _ = try? await subscribeChannelContent(channel)
            let generation = readyGeneration
            Task { [weak self] in await self?.reconcile(channel, generation: generation) }
        }
        await subscriptions.prioritise(channel.flatMap { channelContentSubscriptions[$0] })
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
