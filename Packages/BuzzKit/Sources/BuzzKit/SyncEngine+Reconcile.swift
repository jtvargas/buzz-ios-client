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

    // MARK: - Refresh

    /// A catch-up the reader asked for — the pull-to-refresh path.
    ///
    /// # What it does, by what the connection is doing
    ///
    /// - **Running:** re-runs the work a fresh socket runs — discovery, subscription
    ///   reconciliation, the per-channel head window, and an outbox drain — and awaits
    ///   it, so the spinner lasts exactly as long as the catch-up does. A catch-up
    ///   already in flight is *joined* rather than duplicated: two reconciles of one
    ///   channel would race on the watermark the whole contiguity contract rests on.
    /// - **Anything else:** asks the connection to reopen now rather than wait out its
    ///   backoff, and returns. Deliberately without waiting for `.ready` — the useful
    ///   thing a pull can do for a disconnected client is stop the waiting, and what
    ///   happens next is already reported by the connection state the app draws. Holding
    ///   the spinner through a reconnect that may take a whole backoff would say less,
    ///   for longer.
    ///
    /// A stopped engine (signed out) does nothing at all.
    public func refresh() async {
        guard !isStopped else { return }
        if directoryContext != nil {
            if state != .running {
                await connection.reconnectNow()
            }
            _ = await requestDirectoryRefreshAndWait()
            return
        }
        guard state == .running else {
            await connection.reconnectNow()
            return
        }
        if readyWorkInFlight, let inFlight = onReadyTask {
            await inFlight.value
            return
        }
        let generation = readyGeneration
        readyWorkInFlight = true
        let task: Task<Void, Never> = Task { [weak self] in
            await self?.onReady(generation: generation)
        }
        onReadyTask = task
        await task.value
    }

    // MARK: - On-ready orchestration

    /// The work a fresh, authenticated socket triggers, in order: discover group
    /// state, reconcile each known channel's head, then drain the outbox. Every
    /// step re-checks the ready generation so a reconnect that supersedes this
    /// socket abandons the rest rather than committing against a stale epoch.
    func onReady(generation: Int) async {
        // Cleared only by the run that is still current: a superseded run unwinding
        // after a fresh `.ready` has already armed the flag must not clear the new
        // run's claim. See ``SyncEngine/readyWorkInFlight``.
        defer { if generation == readyGeneration { readyWorkInFlight = false } }

        // Backwards-compatible test seam for existing scripted WebSocket
        // harnesses. Production always injects the authoritative HTTP client.
        let discovered = await discover(generation: generation)
        guard isCurrent(generation) else { return }
        let known = (try? await store.knownChannels()) ?? []
        guard isCurrent(generation) else { return }
        let channels = discovered.union(known)

        await ensureChannelSubscriptions(channels)
        guard isCurrent(generation) else { return }

        Task { [weak self] in await self?.requestPresenceSnapshot(generation: generation) }

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

    // MARK: - Cold-start presence snapshot

    /// Fetches the relay's current-presence snapshot: a one-shot REQ naming every
    /// known member as an author. The relay answers such a REQ — one whose filters all
    /// target `kind:20001` with a non-empty `authors` list — with synthesized
    /// kind-20001 events read from its live presence store (`bridge.rs`
    /// `synthesize_presence`), each relay-signed and carrying its subject in a `p` tag.
    /// This gives an instant who's-online roster at launch instead of waiting up to a
    /// heartbeat interval (60 s) for the first live 20001.
    ///
    /// The events flow through the store's verification choke point like any batch: they
    /// are ephemeral, so they divert into ``IngestResult/ephemeral`` and reach the
    /// presence store, which keys each by its `p`-tag subject rather than the relay
    /// author. Best-effort throughout — no discovered members, a relay that does not
    /// synthesize, or a superseded generation all simply leave the roster to fill from
    /// live heartbeats, exactly as before.
    func requestPresenceSnapshot(generation: Int) async {
        let authors = (try? await store.allMemberPubkeys()) ?? []
        guard !authors.isEmpty else { return }
        let filter = Filter(authors: Array(authors), kinds: [.presence])
        let events = (try? await subscriptions.query([filter])) ?? []
        guard isCurrent(generation) else { return }
        guard let result = try? await store.ingest(batch: events, phase: .backfill),
              !result.ephemeral.isEmpty
        else { return }
        await presence.apply(result.ephemeral)
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

        // Notices come from neither path below, so they are fetched for both — but
        // *detached*, never awaited. Sequencing them ahead of the window would put a
        // relay round-trip for furniture in front of the messages, so a slow or
        // unanswered notice query would stall the whole channel's reconcile behind it.
        // The existing engine suite caught exactly that. Same shape as the presence
        // snapshot above, and for the same reason.
        Task { [weak self] in await self?.assembleNotices(channel, generation: generation) }

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

    // MARK: - Relay notices

    /// Fetches a channel's relay notices — *somebody joined, was added, left, the topic
    /// changed* — which no other path in this engine can reach.
    ///
    /// # Why they need their own fetch
    ///
    /// A kind-40099 notice is stored by the relay through `insert_event`, **not**
    /// `insert_event_with_thread_metadata` (`side_effects.rs`, `emit_system_message`).
    /// It therefore has no `thread_metadata` row — and a channel window page is computed
    /// *from* that table. No value of `kinds` on a window request can return one, so
    /// widening ``reconcileStep``'s filter would look like the fix and do nothing.
    ///
    /// The only other route is the live subscription, whose `since` reaches back
    /// ``SyncEngineConfig/liveSinceWindow`` — five seconds. So without this, a notice is
    /// visible only to a client subscribed to that channel in the moment it happened, and
    /// invisible for ever afterwards. Reported by the owner 2026-08-01: a member added
    /// days earlier rendered on the Flutter client and was absent here, because this
    /// device had never held the event at all.
    ///
    /// # Shape
    ///
    /// An ordinary NIP-01 one-shot — ``fallbackAssemble``'s mechanism, so this is a
    /// known-good path — ingested as `.backfill`, which keeps it off the live watermark.
    /// No `since`: the point is the notices this device never saw; the limit bounds it.
    ///
    /// Best-effort and deliberately not a gate on sync state: a channel whose notices
    /// could not be fetched is still a channel whose *messages* reconciled, and failing
    /// the whole reconcile over the furniture would be the wrong trade.
    ///
    /// Which is also why the caller runs this **detached rather than awaiting it**. An
    /// earlier draft sequenced it ahead of the window pass, and a relay that never
    /// answered the notice query then held the channel out of `.synced` indefinitely —
    /// not a hypothetical, it timed out a dozen existing engine tests. "Best effort" has
    /// to mean the caller cannot be blocked by it, not merely that its errors are
    /// swallowed.
    func assembleNotices(_ channel: String, generation: Int) async {
        let filter = Filter(
            kinds: [.systemMessage],
            limit: config.noticeBackfillLimit,
            tagQueries: ["h": [channel]]
        )
        let events = (try? await subscriptions.query([filter])) ?? []
        // Superseded during the query: abandon, writing nothing — the new generation
        // owns this channel now.
        guard isCurrent(generation) else { return }
        _ = try? await store.ingest(batch: events, phase: .backfill)
    }
    // MARK: - Thread open

    /// Fetches a thread's replies one-shot by root id and ingests them, so opening a
    /// thread pulls its contents on demand.
    ///
    /// `kind:9` alone is the complete ask: it is the only kind ``BuzzProjector`` turns
    /// into a `thread` row, so nothing else the relay could return would change this
    /// device's count of the thread.
    ///
    /// The fetch is then recorded (``BuzzEventStore/recordThreadFetch(root:)``), which
    /// is what promotes this device's own count over the relay's cached tally for this
    /// root. Recorded only on a complete answer, and only when the ingest succeeded:
    /// claiming to hold a thread that was clipped at the relay's limit, or that failed
    /// to write, would suppress the relay's larger and more correct count in favour of
    /// a local one that is genuinely short.
    public func openThread(root: String) async throws -> [NostrEvent] {
        let limit = config.threadFetchLimit
        let filter = Filter(kinds: [.channelMessage], limit: limit, tagQueries: ["e": [root]])
        let events = try await subscriptions.query([filter])
        guard (try? await store.ingest(batch: events, phase: .backfill)) != nil else { return events }
        if events.count < limit {
            try? await store.recordThreadFetch(root: root)
        }
        return events
    }
}
