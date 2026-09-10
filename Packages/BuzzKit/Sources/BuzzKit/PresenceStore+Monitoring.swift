public extension PresenceStore {
    /// A fresh, in-memory read for an app-owned monitoring session. Unlike the
    /// conversation stream, this exposes heartbeat freshness even when the roster
    /// is unchanged. It never starts subscriptions or reads the database.
    struct MonitoredActivity: Sendable {
        public let pubkey: String
        public let channel: String
        public let thread: String?
        public let remainingLifetime: Duration
    }

    func monitoredActivity() -> [MonitoredActivity] {
        let instant = now()
        return activityRecords.compactMap { key, record in
            guard record.deadline > instant else { return nil }
            return MonitoredActivity(
                pubkey: key.pubkey, channel: key.scope.channel, thread: key.scope.thread,
                remainingLifetime: instant.duration(to: record.deadline)
            )
        }
    }
}
