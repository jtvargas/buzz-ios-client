import BuzzKit
import NostrCore

/// The send/retry surface a timeline needs — the narrow slice of ``SyncEngine``
/// the composer and the "tap to retry" strip call.
///
/// Behind a protocol so a view model's send path is testable against a scripted
/// engine or a stub, and so the model depends on an intent rather than the whole
/// engine actor. ``SyncEngine`` already exposes exactly these two methods, so the
/// conformance is free.
protocol MessageSending: Sendable {
    @discardableResult
    func enqueue(
        kind: EventKind,
        content: String,
        in channel: String,
        tags: [[String]],
        maxContentBytes: Int
    ) async throws -> OutboxEntry

    @discardableResult
    func enqueueMediaMessage(
        kind: EventKind,
        text: String,
        in channel: String,
        tags: [[String]],
        media: [OutboundMediaPayload],
        maxContentBytes: Int
    ) async throws -> OutboxEntry

    func retry(_ eventID: String) async throws

    /// Drops an own queued send — the "delete" action on a pending or failed row.
    func discard(_ eventID: String) async throws
}

extension SyncEngine: MessageSending {}

extension MessageSending {
    @discardableResult
    func enqueueMediaMessage(
        kind _: EventKind,
        text _: String,
        in _: String,
        tags _: [[String]],
        media _: [OutboundMediaPayload],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        throw OutboxError.mediaUnavailable
    }

    /// The one channel/thread seam that chooses the existing text enqueue or the
    /// durable staged-media enqueue without duplicating that decision in both models.
    @discardableResult
    func enqueueComposerMessage(
        text: String,
        in channel: String,
        tags: [[String]],
        media: [OutboundMediaPayload]
    ) async throws -> OutboxEntry {
        if media.isEmpty {
            return try await enqueue(
                kind: .channelMessage,
                content: text,
                in: channel,
                tags: tags,
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        }
        return try await enqueueMediaMessage(
            kind: .channelMessage,
            text: text,
            in: channel,
            tags: tags,
            media: media,
            maxContentBytes: OutboxPolicy.maxContentBytes
        )
    }
}
