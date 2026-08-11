import NostrCore

/// The observation half of ``PresenceStore``: the live streams and point-in-time
/// snapshots the app subscribes to, plus the change-suppressed publish that pushes
/// updates to them. Split from the core so the ingest/expiry logic and the
/// observer plumbing each stay legible.
public extension PresenceStore {
    // MARK: - Presence (workspace-global)

    /// A live feed of the workspace presence roster, seeded with the current
    /// snapshot so a new subscriber never misses the state it subscribed into
    /// (mirroring the connection-state stream in the transport layer). Members are
    /// ordered by pubkey, so two equal rosters compare equal.
    func workspacePresence() -> AsyncStream<[PresenceMember]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [PresenceMember].self)
        let id = nextObserverID
        nextObserverID += 1
        presenceObservers[id] = continuation
        continuation.yield(presenceSnapshotNow())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removePresenceObserver(id) }
        }
        return stream
    }

    /// The current presence roster, lapsed records already excluded. A pure read: it
    /// neither mutates state nor notifies observers.
    func workspacePresenceSnapshot() -> [PresenceMember] {
        presenceSnapshotNow()
    }

    // MARK: - Typing (per channel, per thread)

    /// A live feed of who is typing, seeded with the current snapshot. Pubkeys are
    /// ordered and distinct, so two equal typer sets compare equal.
    ///
    /// `thread` names a thread root to listen to, and that feed carries only the people
    /// writing in that thread. Omitted, the feed is the channel's own level — and *not*
    /// its threads, so an agent replying inside one is silent here. The partition is the
    /// point: see the note on ``PresenceStore/TypingAudience``.
    func typing(in channel: String, thread: String? = nil) -> AsyncStream<[String]> {
        let audience = Self.audience(channel: channel, thread: thread)
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let id = nextObserverID
        nextObserverID += 1
        typingObservers[audience, default: [:]][id] = continuation
        continuation.yield(typingSnapshotNow(audience))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTypingObserver(id, audience: audience) }
        }
        return stream
    }

    /// The current typers for one audience, lapsed records already excluded.
    func typingSnapshot(in channel: String, thread: String? = nil) -> [String] {
        typingSnapshotNow(Self.audience(channel: channel, thread: thread))
    }
}

extension PresenceStore {
    // MARK: - Publishing

    /// Evicts lapsed presence, then yields a fresh roster to its observers only if it
    /// differs from the last one published.
    func publishPresence() {
        evictPresence()
        let snapshot = presenceSnapshotNow()
        guard snapshot != lastPublishedPresence else { return }
        lastPublishedPresence = snapshot
        for continuation in presenceObservers.values {
            continuation.yield(snapshot)
        }
    }

    /// Evicts lapsed typers in the scopes that changed, then yields a fresh typer list to
    /// every audience those scopes belong to — the threads themselves and the channels
    /// containing them.
    ///
    /// Takes the whole set rather than one scope at a time because two touched scopes in
    /// one channel share that channel's audience, and publishing per scope would yield to
    /// it twice for one batch.
    func publishTyping(_ scopes: Set<TypingScope>) {
        guard !scopes.isEmpty else { return }
        for scope in scopes { evictTyping(scope) }
        var audiences: Set<TypingAudience> = []
        for scope in scopes { audiences.formUnion(TypingAudience.containing(scope)) }
        for audience in audiences { publish(audience) }
    }

    /// Yields one audience's current typers to its observers, but only if the list
    /// differs from the last one published to it.
    private func publish(_ audience: TypingAudience) {
        let snapshot = typingSnapshotNow(audience)
        let previous = lastPublishedTyping[audience] ?? []
        guard previous != snapshot else { return }
        if snapshot.isEmpty {
            lastPublishedTyping.removeValue(forKey: audience)
        } else {
            lastPublishedTyping[audience] = snapshot
        }
        guard let observers = typingObservers[audience] else { return }
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
    }

    /// The audience a `(channel, thread)` pair names: one thread when a root is given,
    /// the whole channel when none is.
    static func audience(channel: String, thread: String?) -> TypingAudience {
        guard let thread else { return .channel(channel) }
        return .thread(TypingScope(channel: channel, thread: thread))
    }

    // MARK: - Snapshots

    /// The live presence roster, treating any record past its deadline as already
    /// gone. Ordered by pubkey so equal rosters compare equal.
    func presenceSnapshotNow() -> [PresenceMember] {
        let cutoff = now()
        return presenceRecords.values
            .filter { $0.deadline > cutoff }
            .map { PresenceMember(pubkey: $0.pubkey, status: $0.status) }
            .sorted { $0.pubkey < $1.pubkey }
    }

    /// The live typers one audience hears, lapsed records excluded, ordered by pubkey.
    ///
    /// `Set` is defensive, not load-bearing. Every audience now admits exactly one scope,
    /// and records are keyed `(scope, pubkey)`, so one person cannot appear twice. It was
    /// load-bearing while a channel spanned its threads — one person writing in two of
    /// them was two records and one typer — and it is kept because the cost is nothing and
    /// the invariant it protects is not local to this function.
    func typingSnapshotNow(_ audience: TypingAudience) -> [String] {
        let cutoff = now()
        let pubkeys = typingRecords
            .filter { audience.admits($0.key.scope) && $0.value.deadline > cutoff }
            .map(\.value.pubkey)
        return Set(pubkeys).sorted()
    }

    // MARK: - Eviction

    func evictPresence() {
        let cutoff = now()
        presenceRecords = presenceRecords.filter { $0.value.deadline > cutoff }
    }

    func evictTyping(_ scope: TypingScope) {
        let cutoff = now()
        typingRecords = typingRecords.filter { key, record in
            key.scope != scope || record.deadline > cutoff
        }
    }

    // MARK: - Observer teardown

    func removePresenceObserver(_ id: Int) {
        presenceObservers.removeValue(forKey: id)
    }

    func removeTypingObserver(_ id: Int, audience: TypingAudience) {
        typingObservers[audience]?.removeValue(forKey: id)
        if typingObservers[audience]?.isEmpty == true {
            typingObservers.removeValue(forKey: audience)
        }
    }
}
