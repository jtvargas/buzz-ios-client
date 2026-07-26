import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The states around opening a direct message: in flight, navigable, failed — and the
/// one rule that matters for correctness, which is that a second tap while the first
/// open is in flight does not send a second one.
@MainActor
@Suite("Direct message router", .timeLimit(.minutes(1)))
struct DirectMessageRouterTests {
    /// A controllable opener: it records what it was asked for and answers on demand, so
    /// a test can observe the in-flight state rather than racing it.
    private final class StubOpener: DirectMessageOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var _peers: [String] = []
        private var _result: Result<String, any Error>?

        var peers: [String] {
            lock.withLock { _peers }
        }

        func answer(_ result: Result<String, any Error>) {
            lock.withLock { _result = result }
        }

        func openDirectMessage(with peer: String) async throws -> String {
            lock.withLock { _peers.append(peer) }
            while true {
                if let result = lock.withLock({ _result }) {
                    return try result.get()
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func settle() async {
        // A real sleep, not `Task.yield()`: the router hops to its own task and the
        // stub sleeps, so yielding can return before either has run.
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test("a successful open becomes a channel to navigate to, exactly once")
    func opensAndNavigates() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        #expect(router.isOpening)
        #expect(router.pendingChannelID == nil)

        opener.answer(.success("channel-9"))
        await settle()

        #expect(!router.isOpening)
        #expect(router.pendingChannelID == "channel-9")
        #expect(router.failure == nil)
        #expect(opener.peers == ["peer-1"])

        // The consumer clears it; nothing re-publishes it afterwards.
        router.pendingChannelID = nil
        await settle()
        #expect(router.pendingChannelID == nil)
    }

    @Test("a second tap while an open is in flight is ignored, not queued")
    func ignoresConcurrentTaps() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        router.open(with: "peer-1")
        router.open(with: "peer-2")

        opener.answer(.success("channel-9"))
        await settle()

        // One request reached the engine. Opening a DM is idempotent relay-side, but a
        // double tap must not produce two navigations either.
        #expect(opener.peers == ["peer-1"])
        #expect(router.pendingChannelID == "channel-9")
    }

    @Test("a failure surfaces a sentence and leaves nothing to navigate to")
    func surfacesFailure() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        opener.answer(.failure(DirectMessageError.rejected(.restricted("not a relay member"))))
        await settle()

        #expect(!router.isOpening)
        #expect(router.pendingChannelID == nil)
        #expect(router.failure == "The relay would not open this conversation for you.")

        // And the router is usable again afterwards — a failure is not a dead end.
        router.failure = nil
        opener.answer(.success("channel-2"))
        router.open(with: "peer-1")
        await settle()
        #expect(router.pendingChannelID == "channel-2")
    }

    @Test("every typed failure maps to a distinct reader-facing sentence")
    func failureMessages() {
        let restricted = DirectMessageRouter.message(
            for: DirectMessageError.rejected(.restricted("nope"))
        )
        let invalidKey = DirectMessageRouter.message(for: DirectMessageError.invalidPeerPubkey("x"))
        let malformed = DirectMessageRouter.message(for: DirectMessageError.malformedResponse("{}"))
        let offline = DirectMessageRouter.message(
            for: DirectMessageError.publishFailed(.connectionLost)
        )
        let unknown = DirectMessageRouter.message(for: CancellationError())

        // Distinct, so a reader can tell "you are not allowed" from "you are offline".
        #expect(Set([restricted, invalidKey, malformed, offline, unknown]).count == 5)
        #expect(!restricted.isEmpty)
        // Never leaks a raw error description at the reader.
        #expect(!malformed.contains("{}"))
    }
}
