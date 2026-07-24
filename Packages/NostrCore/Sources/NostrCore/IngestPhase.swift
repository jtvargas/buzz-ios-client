import Foundation

/// Which half of a subscription's lifetime a batch of events belongs to.
///
/// A relay answers a `REQ` by first replaying the events it already has, then
/// sending an `EOSE` to mark the boundary, after which everything is live. The
/// distinction matters to the sink: the stored replay is a bounded catch-up that
/// can be written in large batches, whereas live events are a latency-sensitive
/// trickle. Marking each batch with its phase lets the store treat the two
/// differently — for example, deferring expensive projection work until the
/// backfill has drained — without the manager having to know how.
public enum IngestPhase: Sendable, Equatable {
    /// Stored events replayed before the subscription's first `EOSE`.
    case backfill
    /// Events arriving live, after the subscription has caught up.
    case live
}
