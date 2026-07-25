import Foundation
import NostrCore

/// Channel discovery, the per-channel window reconcile that closes the offline
/// gap, the degradation fallback, and the thread-open query.
extension SyncEngine {
    /// The relay-signed group state, fetched one-shot on every `.ready`. Group
    /// state is addressable and does not ride the live content fan-out, so a fresh
    /// socket re-queries it directly.
    static let discoveryFilter = Filter(
        kinds: [.groupMetadata, .groupAdmins, .groupMembers]
    )

    // MARK: - On-ready orchestration

    /// The work a fresh, authenticated socket triggers, in order: discover group
    /// state, reconcile each known channel's head, then drain the outbox. Every
    /// step re-checks the ready generation so a reconnect that supersedes this
    /// socket abandons the rest rather than committing against a stale epoch.
    func onReady(generation: Int) async {
        let discovered = await discover(generation: generation)
        guard isCurrent(generation) else { return }

        let known = (try? await store.knownChannels()) ?? []
        guard isCurrent(generation) else { return }

        let channels = discovered.union(known)

        // Ensure a standing content subscription for every discovered/known channel
        // *before* the head reconcile: registration is a cheap socket REQ that returns
        // at once, so live channel traffic starts flowing while the (possibly slow,
        // HTTP-paged) reconcile runs. This is the only live path for channel-scoped
        // events — the global REQ never receives them. Add-only: departures are handled
        // by membership events and relay CLOSEs, not a discovery gap.
        await ensureChannelSubscriptions(channels)
        guard isCurrent(generation) else { return }

        // Sorted so the reconcile order — and therefore the scripted HTTP request
        // order in tests — is deterministic.
        for channel in channels.sorted() {
            guard isCurrent(generation) else { return }
            await reconcile(channel, generation: generation)
        }

        guard isCurrent(generation) else { return }
        await requestDrain(generation: generation)
    }

    /// Whether `generation` is still the current ready epoch and the engine is
    /// running — the guard every on-ready step consults before committing state.
    func isCurrent(_ generation: Int) -> Bool {
        !isStopped && state == .running && generation == readyGeneration
    }

    // MARK: - Discovery

    /// Queries the relay-signed group state, ingests it (so the channel and roster
    /// projections update), and returns the discovered channel ids.
    @discardableResult
    func discover(generation: Int) async -> Set<String> {
        let events = (try? await subscriptions.query([Self.discoveryFilter])) ?? []
        guard isCurrent(generation) else { return [] }
        _ = try? await store.ingest(batch: events, phase: .backfill)
        return channelIDs(inMetadata: events)
    }

    /// Re-fetches one channel's group state, then reconciles its head — the
    /// response to a membership add/remove for that channel.
    func rediscoverAndReconcile(_ channel: String, generation: Int) async {
        let filter = Filter(
            kinds: [.groupMetadata, .groupAdmins, .groupMembers],
            tagQueries: ["d": [channel]]
        )
        let events = (try? await subscriptions.query([filter])) ?? []
        guard isCurrent(generation) else { return }
        _ = try? await store.ingest(batch: events, phase: .backfill)
        await reconcile(channel, generation: generation)
    }

    /// The channel ids named by the `d` tag of the kind-39000 metadata events in a
    /// discovery response.
    private func channelIDs(inMetadata events: [NostrEvent]) -> Set<String> {
        Set(events.compactMap { $0.kind == .groupMetadata ? $0.addressableIdentifier : nil })
    }

    // MARK: - Reconcile

    /// Closes the offline gap for one channel by paging the head window down until a
    /// page's oldest row reaches the stored watermark, or the relay reports no more
    /// pages.
    ///
    /// The watermark advances to the head page's newest row exactly once — in the
    /// transaction that commits the gap-closing page (rule 3) — so a crash mid-page
    /// leaves it untouched and the next launch re-pages from the head for free. An
    /// `.invalidPage` discards that page and leaves the channel unsynced; a
    /// `.degraded` result withdraws the fast path for the session and falls back to
    /// the standard WebSocket filter.
    ///
    /// Every step re-checks `isCurrent(generation)`: a reconnect that supersedes this
    /// socket abandons the reconcile, and abandoning writes nothing — the new
    /// generation already reset channel state and owns it, so a late write from here
    /// could only clobber it.
    func reconcile(_ channel: String, generation: Int) async {
        guard isCurrent(generation) else { return }
        setChannelState(channel, .reconciling)

        if windowDegraded {
            await fallbackAssemble(channel, generation: generation)
            return
        }

        let watermark = try? await store.channelWatermark(channel)
        var headNewest: WindowCursor?
        var cursor: WindowRequestCursor = .head

        while isCurrent(generation) {
            switch await reconcileStep(
                channel: channel, from: cursor, watermark: watermark,
                headNewest: &headNewest, generation: generation
            ) {
            case let .fetchNext(next):
                cursor = next
            case .stop:
                return
            }
        }
        // The loop exits here only because `isCurrent` went false — a reconnect
        // superseded this reconcile mid-page. Abandoning means writing nothing: the
        // fresh `.ready` that superseded it already reset every channel, and a late
        // `.unsynced` here would clobber whatever state the new generation has since
        // set (e.g. a `.synced` it has already reached).
    }

    /// The outcome of one reconcile page: page again from a new cursor, or stop
    /// (the step has already set the channel's terminal sync state).
    private enum ReconcileStep {
        case fetchNext(WindowRequestCursor)
        case stop
    }

    /// Fetches and commits one page, returning whether the loop continues. Every
    /// terminal path sets the channel state before returning ``ReconcileStep/stop``,
    /// so the caller's loop stays a thin driver.
    private func reconcileStep(
        channel: String,
        from cursor: WindowRequestCursor,
        watermark: WindowCursor?,
        headNewest: inout WindowCursor?,
        generation: Int
    ) async -> ReconcileStep {
        let filter = WindowFilter(
            channelID: channel, cursor: cursor, kinds: [.channelMessage], limit: config.windowPageLimit
        )
        guard let result = try? await windowClient.fetch(filter) else {
            // The request could not be *formed* (signer/encoder). If this generation
            // is still current, leave the channel unsynced so a later `.ready`
            // retries; if a reconnect superseded it during the fetch, abandon without
            // a write — a stale task must never touch state the new socket now owns.
            if isCurrent(generation) { setChannelState(channel, .unsynced) }
            return .stop
        }
        // Superseded during the fetch: abandon, writing nothing (see below).
        guard isCurrent(generation) else { return .stop }

        switch result {
        case let .page(page):
            let decision = pageDecision(page, watermark: watermark, headNewest: &headNewest)
            _ = try? await store.commitWindowPage(page, channel: channel, advanceWatermarkTo: decision.advanceTo)
            // Superseded during the commit: abandon, writing nothing. The page itself
            // is already durably committed by its own transaction; only the channel
            // *state* is abandoned, and the new generation owns that now.
            guard isCurrent(generation) else { return .stop }
            guard let next = decision.next else {
                setChannelState(channel, .synced)
                return .stop
            }
            return .fetchNext(next)

        case .invalidPage:
            // Discard the page, watermark untouched; the fast path stays available
            // for the next `.ready`.
            setChannelState(channel, .unsynced)
            return .stop

        case .degraded:
            windowDegraded = true
            await fallbackAssemble(channel, generation: generation)
            return .stop
        }
    }

    /// The pure cursor math for one page: whether to advance the watermark (only on
    /// the gap-closing page, to the head's newest row) and which cursor to fetch
    /// next (`nil` means the gap is closed). The first page seen is the head page,
    /// whose newest row is remembered for the eventual advance.
    private func pageDecision(
        _ page: WindowPage,
        watermark: WindowCursor?,
        headNewest: inout WindowCursor?
    ) -> (advanceTo: WindowCursor?, next: WindowRequestCursor?) {
        let rowCursors = page.rows.map { WindowCursor(createdAt: $0.createdAt, id: $0.id) }
        if headNewest == nil { headNewest = rowCursors.max() }

        let reachedWatermark: Bool = if let watermark, let oldest = rowCursors.min() {
            oldest <= watermark
        } else {
            false
        }

        // Gap closed by overlap or exhaustion, or a `hasMore` with no usable cursor
        // (unreachable past the parser, treated as closed): advance the watermark.
        if reachedWatermark || !page.bounds.hasMore {
            return (headNewest, nil)
        }
        guard let next = page.bounds.nextCursor else {
            return (headNewest, nil)
        }
        return (nil, .after(next))
    }

    // MARK: - Degradation fallback

    /// Assembles a channel's history from the standard WebSocket filter when the
    /// window path has degraded: the clean NIP-01 projection of the window request
    /// (kinds + `#h` + limit), run one-shot and ingested. Threads reassemble
    /// client-side through the normal projector.
    ///
    /// This is a single limit-bounded page with no `since`, so it recovers the head
    /// of the channel but proves nothing about the gap below it. The channel is
    /// therefore marked ``ChannelSync/fallbackSynced``, **not** ``ChannelSync/synced``:
    /// it renders as caught up, but it is excluded from ``syncedChannels()`` so a
    /// live flush never advances the watermark over an unclosed gap (rule 2's
    /// contiguity contract). The watermark stays where it was until a later `.ready`
    /// reconciles this channel through the window path and closes the gap honestly.
    func fallbackAssemble(_ channel: String, generation: Int) async {
        let filter = WindowFilter(channelID: channel, kinds: [.channelMessage], limit: config.windowPageLimit)
            .baseFilter
        let events = (try? await subscriptions.query([filter])) ?? []
        // Superseded during the query: abandon, writing nothing — the new generation
        // owns this channel's state now.
        guard isCurrent(generation) else { return }
        _ = try? await store.ingest(batch: events, phase: .backfill)
        setChannelState(channel, .fallbackSynced)
    }

    // MARK: - Thread open

    /// Fetches a thread's replies one-shot by root id and ingests them, so opening a
    /// thread pulls its contents on demand. Engine support only — the UI is Phase 3.
    public func openThread(root: String) async throws -> [NostrEvent] {
        let filter = Filter(kinds: [.channelMessage], tagQueries: ["e": [root]])
        let events = try await subscriptions.query([filter])
        _ = try? await store.ingest(batch: events, phase: .backfill)
        return events
    }
}
