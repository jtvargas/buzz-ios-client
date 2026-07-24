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

    func retry(_ eventID: String) async throws
}

extension SyncEngine: MessageSending {}
