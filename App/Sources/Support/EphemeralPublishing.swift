import BuzzKit
import NostrCore

/// The ephemeral-publish surface presence and typing need — the narrow slice of
/// ``SyncEngine`` the heartbeat and the composer's typing sender call.
///
/// Behind a protocol so a view model's typing path and the heartbeat are testable
/// against a recording double, and so those callers depend on an intent (fire an
/// ephemeral) rather than the whole engine actor. ``SyncEngine`` already exposes
/// exactly this method, so the conformance is free.
protocol EphemeralPublishing: Sendable {
    /// Publishes an ephemeral event (presence, typing) best-effort — never queued,
    /// never retried, failures dropped.
    func publishEphemeral(kind: EventKind, content: String, tags: [[String]]) async
}

extension SyncEngine: EphemeralPublishing {}

/// A no-op ``EphemeralPublishing`` for the pure-observation and pagination view-model
/// tests, and the default a ``ChannelTimelineModel`` takes when no typing sink is
/// wired (previews). Publishing nothing is exactly the intent there.
struct NoopEphemeralPublisher: EphemeralPublishing {
    func publishEphemeral(kind _: EventKind, content _: String, tags _: [[String]]) async {}
}
