import BuzzKit

/// Marking a channel read up to a message — the narrow slice of ``SyncEngine`` the
/// timeline drives for mark-on-view.
///
/// Behind a protocol so the timeline model depends on an intent rather than the whole
/// engine actor, and so a test can record the marks a visible channel emits against a
/// scripted double. ``SyncEngine`` already exposes exactly this method (publishing the
/// NIP-RS read-state blob through the durable outbox), so the conformance is free.
protocol ReadStateMarking: Sendable {
    /// Marks `channel` read up to `upTo` (a message `created_at`, unix seconds).
    /// Grow-only and best-effort on the engine side.
    func markRead(channel: String, upTo: Int64) async
}

extension SyncEngine: ReadStateMarking {}
