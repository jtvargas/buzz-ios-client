public extension PresenceStore {
    /// A fresh, in-memory read for an app-owned monitoring session. Unlike the
    /// conversation stream, this exposes heartbeat freshness even when the roster
    /// is unchanged. It never starts subscriptions or reads the database.
    struct MonitoredActivity: Sendable {
        public let pubkey: String
        public let channel: String
        public let thread: String?
        public let receivedAt: ContinuousClock.Instant
        public let remainingLifetime: Duration
    }

    func monitoredActivity() -> [MonitoredActivity] {
        let instant = now()
        return activityRecords.compactMap { key, record in
            guard record.deadline > instant else { return nil }
            return MonitoredActivity(
                pubkey: key.pubkey, channel: key.scope.channel, thread: key.scope.thread,
                receivedAt: record.deadline.advanced(by: .zero - typingTTL),
                remainingLifetime: instant.duration(to: record.deadline)
            )
        }
    }

    /// Unseeded, coalesced notifications for newly accepted working/typing
    /// heartbeats. Read `monitoredActivity()` after a notification for fresh state.
    /// Observing adds no relay subscriptions, polling, or background execution.
    func monitoringHeartbeats() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let id = nextObserverID
        nextObserverID += 1
        monitoringObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeMonitoringObserver(id) }
        }
        return stream
    }
}

extension PresenceStore {
    func publishMonitoringHeartbeat() {
        for continuation in monitoringObservers.values { continuation.yield(()) }
    }

    private func removeMonitoringObserver(_ id: Int) {
        monitoringObservers.removeValue(forKey: id)
    }
}
