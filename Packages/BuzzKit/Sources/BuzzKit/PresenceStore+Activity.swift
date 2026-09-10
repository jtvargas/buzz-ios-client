/// Conversation activity uses two views of the same heartbeat: a message ends human
/// typing, while an agent may post progress and continue working until heartbeats stop.
public extension PresenceStore {
    struct ActivitySnapshot: Sendable, Equatable {
        /// Participants whose typing has not been superseded by a message.
        public let typing: [String]
        /// All participants with a recent heartbeat. Consumers select known agents.
        public let active: [String]

        static let empty = ActivitySnapshot(typing: [], active: [])
    }

    /// A seeded, bounded feed scoped exactly like ``typing(in:thread:)``. Keeping both
    /// lists in one snapshot lets the UI classify identities without a database query
    /// on each heartbeat or a second subscription to the relay.
    func conversationActivity(in channel: String, thread: String? = nil) -> AsyncStream<ActivitySnapshot> {
        let audience = Self.audience(channel: channel, thread: thread)
        let (stream, continuation) = AsyncStream.makeStream(
            of: ActivitySnapshot.self, bufferingPolicy: .bufferingNewest(1)
        )
        let id = nextObserverID
        nextObserverID += 1
        activityObservers[audience, default: [:]][id] = continuation
        continuation.yield(activitySnapshotNow(audience))
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeActivityObserver(id, audience: audience) }
        }
        return stream
    }

    /// Connection loss invalidates transient activity. Reconnection waits for fresh
    /// heartbeats; no activity is inferred from online presence or cached messages.
    func clearActivity() {
        let scopes = Set(typingRecords.keys.map(\.scope)).union(activityRecords.keys.map(\.scope))
        typingRecords.removeAll()
        activityRecords.removeAll()
        messageMarks.removeAll()
        publishTyping(scopes)
    }
}

extension PresenceStore {
    func publishActivity(_ audience: TypingAudience) {
        let snapshot = activitySnapshotNow(audience)
        guard snapshot != lastPublishedActivity[audience, default: .empty] else { return }
        if snapshot == .empty {
            lastPublishedActivity.removeValue(forKey: audience)
        } else {
            lastPublishedActivity[audience] = snapshot
        }
        guard let observers = activityObservers[audience] else { return }
        for continuation in observers.values { continuation.yield(snapshot) }
    }

    private func activitySnapshotNow(_ audience: TypingAudience) -> ActivitySnapshot {
        let cutoff = now()
        let active = activityRecords
            .filter { audience.admits($0.key.scope) && $0.value.deadline > cutoff }
            .map(\.value.pubkey)
            .sorted()
        return ActivitySnapshot(typing: typingSnapshotNow(audience), active: active)
    }

    private func removeActivityObserver(_ id: Int, audience: TypingAudience) {
        activityObservers[audience]?.removeValue(forKey: id)
        if activityObservers[audience]?.isEmpty == true {
            activityObservers.removeValue(forKey: audience)
        }
    }
}
