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
    /// Grow-only and best-effort on the engine side, and **coalesced** — the publish
    /// follows a short window rather than this call.
    func markRead(channel: String, upTo: Int64) async

    /// Publishes whatever that window is holding, now.
    ///
    /// Called where a surface that renders read state is about to be looked at — leaving a
    /// conversation — and on the way out of the foreground. A no-op when nothing is pending,
    /// so a caller needs no condition of its own.
    func flushReadMarks() async
}

extension SyncEngine: ReadStateMarking {}
