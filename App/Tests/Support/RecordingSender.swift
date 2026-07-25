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
        return OutboxEntry(event: event, channelID: channel, state: .pending, attempts: 0, lastError: nil)
    }

    func retry(_ eventID: String) async throws {
        retried.append(eventID)
    }

    func discard(_ eventID: String) async throws {
        discarded.append(eventID)
    }
}
