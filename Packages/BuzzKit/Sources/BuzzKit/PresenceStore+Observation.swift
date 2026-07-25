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

    // MARK: - Typing (per channel)

    /// A live feed of who is typing in one channel, seeded with the current snapshot.
    /// Pubkeys are ordered, so two equal typer sets compare equal.
    func typing(in channel: String) -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let id = nextObserverID
        nextObserverID += 1
        typingObservers[channel, default: [:]][id] = continuation
        continuation.yield(typingSnapshotNow(channel))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeTypingObserver(id, channel: channel) }
        }
        return stream
    }

    /// The current typers in a channel, lapsed records already excluded.
    func typingSnapshot(in channel: String) -> [String] {
        typingSnapshotNow(channel)
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

    /// Evicts lapsed typers for one channel, then yields a fresh typer list to its
    /// observers only if it differs from the last one published.
    func publishTyping(_ channel: String) {
        evictTyping(channel)
        let snapshot = typingSnapshotNow(channel)
        let previous = lastPublishedTyping[channel] ?? []
        guard previous != snapshot else { return }
        if snapshot.isEmpty {
            lastPublishedTyping.removeValue(forKey: channel)
        } else {
            lastPublishedTyping[channel] = snapshot
        }
        guard let observers = typingObservers[channel] else { return }
        for continuation in observers.values {
            continuation.yield(snapshot)
        }
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

    /// The live typers in one channel, lapsed records excluded, ordered by pubkey.
    func typingSnapshotNow(_ channel: String) -> [String] {
        let cutoff = now()
        return typingRecords
            .filter { $0.key.channel == channel && $0.value.deadline > cutoff }
            .map(\.value.pubkey)
            .sorted()
    }

    // MARK: - Eviction

    func evictPresence() {
        let cutoff = now()
        presenceRecords = presenceRecords.filter { $0.value.deadline > cutoff }
    }

    func evictTyping(_ channel: String) {
        let cutoff = now()
        typingRecords = typingRecords.filter { key, record in
            key.channel != channel || record.deadline > cutoff
        }
    }

    // MARK: - Observer teardown

    func removePresenceObserver(_ id: Int) {
        presenceObservers.removeValue(forKey: id)
    }

    func removeTypingObserver(_ id: Int, channel: String) {
        typingObservers[channel]?.removeValue(forKey: id)
        if typingObservers[channel]?.isEmpty == true {
            typingObservers.removeValue(forKey: channel)
        }
    }
}
