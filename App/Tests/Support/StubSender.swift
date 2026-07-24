import BuzzKit
@testable import Hive
import NostrCore

/// A no-op ``MessageSending`` for the pure-observation and pagination tests, where
/// nothing is sent. Being called is a test bug, so it fails loudly rather than
/// silently succeeding.
struct StubSender: MessageSending {
    enum StubError: Error { case unexpectedSend }

    func enqueue(
        kind _: EventKind,
        content _: String,
        in _: String,
        tags _: [[String]],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        throw StubError.unexpectedSend
    }

    func retry(_: String) async throws {
        throw StubError.unexpectedSend
    }
}
