import BuzzKit
@testable import Hive
import Foundation
import NostrCore

/// A ``MessageSending`` double that records every call, so a model test can assert
/// the exact kind, content, channel, and tags an action put on the durable send
/// path — the reaction, withdrawal, and reply wire shapes — without a live engine.
///
/// It signs a real event for the entry it returns (with a throwaway key), so the
/// returned ``OutboxEntry`` is well-formed even though the tests read the recorded
/// call rather than the entry.
actor RecordingSender: MessageSending {
    struct Sent: Sendable, Equatable {
        let kind: EventKind
        let content: String
        let channel: String
        let tags: [[String]]
    }

    private(set) var sent: [Sent] = []
    /// The signed events behind ``sent``, in the same order.
    ///
    /// Nothing stores them here — this double queues nothing — so a test that needs the
    /// message to *arrive* ingests one of these into its own store, which is the path the
    /// outbox commit takes on a device.
    private(set) var events: [NostrEvent] = []
    private(set) var retried: [String] = []
    private(set) var discarded: [String] = []

    private let key: PrivateKey

    init() throws {
        key = try PrivateKey()
    }

    @discardableResult
    func enqueue(
        kind: EventKind,
        content: String,
        in channel: String,
        tags: [[String]],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        sent.append(Sent(kind: kind, content: content, channel: channel, tags: tags))
        let event = try NostrEvent.signed(kind: kind, content: content, tags: tags, createdAt: Date(), with: key)
        events.append(event)
        return OutboxEntry(event: event, channelID: channel, state: .pending, attempts: 0, lastError: nil)
    }

    @discardableResult
    func enqueueMediaMessage(
        kind: EventKind,
        text: String,
        in channel: String,
        tags: [[String]],
        media: [OutboundMediaPayload],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        guard let baseURL = URL(string: "https://relay.example.com") else {
            throw OutboxError.mediaStagingFailed
        }
        let descriptors = try media.map { payload in
            guard let descriptor = BlobDescriptor.predicted(
                data: payload.data,
                baseURL: baseURL,
                filename: payload.filename
            ) else { throw OutboxError.mediaStagingFailed }
            return descriptor
        }
        return try await enqueue(
            kind: kind,
            content: OutboundAttachments.content(text, attaching: descriptors),
            in: channel,
            tags: tags + OutboundAttachments.tags(attaching: descriptors),
            maxContentBytes: OutboxPolicy.maxContentBytes
        )
    }

    func retry(_ eventID: String) async throws {
        retried.append(eventID)
    }

    func discard(_ eventID: String) async throws {
        discarded.append(eventID)
    }
}
