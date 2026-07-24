import Foundation

/// Batching and replay knobs for a ``SubscriptionManager``.
///
/// Each value is a policy the manager reads rather than hardcodes, so a test can
/// compress the timers and a caller can tune throughput without touching the
/// delivery logic. The defaults trade a little latency for far fewer store
/// round-trips on the hot backfill path, which is the whole point of the batched
/// sink.
public struct SubscriptionManagerConfig: Sendable {
    /// The most events buffered before a flush. During backfill, hitting this
    /// count flushes a batch; during the live phase it caps how large a single
    /// coalesced flush can grow when events arrive in a burst. A relay serves
    /// stored events newest-first, so a backfill flush is a contiguous, ordered
    /// slice of the replay.
    public var batchSize: Int

    /// How long a live-phase flush waits to coalesce near-simultaneous events
    /// into one batch. Short enough to stay imperceptible, long enough that a
    /// small burst becomes a single delivery instead of several.
    public var liveFlushInterval: Duration

    /// How far below the high-water mark a reconnect replay reaches back, to
    /// re-fetch anything the relay accepted in the moment the socket was
    /// dropping. The store dedupes by event id, so the overlap only ever costs a
    /// few redundant events, never a duplicate write.
    public var replayOverlap: Duration

    public init(
        batchSize: Int = 256,
        liveFlushInterval: Duration = .milliseconds(50),
        replayOverlap: Duration = .seconds(5)
    ) {
        self.batchSize = batchSize
        self.liveFlushInterval = liveFlushInterval
        self.replayOverlap = replayOverlap
    }

    public static let `default` = SubscriptionManagerConfig()

    /// The replay overlap expressed in whole seconds, the unit an event's
    /// `created_at` — and therefore a filter's `since` — is measured in.
    var replayOverlapSeconds: Int64 {
        Int64(replayOverlap.components.seconds)
    }
}
