import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The states around opening a direct message: in flight, navigable, failed — the one rule
/// that matters for correctness, which is that a second tap on the *same person* while
/// their open is in flight does not send a second one, and what the navigation surface then
/// does with the result.
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
                // `try`, not `try?`: swallowing the cancellation error here would leave a
                // stub that cannot be cancelled, so a test whose router outlived it would
                // spin this loop to the suite's time limit rather than ending with it.
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func settle() async {
        // A real sleep, not `Task.yield()`: the router hops to its own task and the
        // stub sleeps, so yielding can return before either has run.
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test("a successful open becomes a conversation to navigate to, exactly once")
    func opensAndNavigates() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        #expect(router.isOpening)
        #expect(router.isOpening("peer-1"))
        #expect(router.pendingConversation == nil)

        opener.answer(.success("channel-9"))
        await settle()

        #expect(!router.isOpening)
        // The peer travels with the id: the pushed conversation names itself from it until
        // the roster the relay commits afterwards is readable.
        #expect(router.pendingConversation == OpenedConversation(channelID: "channel-9", peer: "peer-1"))
        #expect(router.failure == nil)
        #expect(opener.peers == ["peer-1"])

        // The consumer clears it; nothing re-publishes it afterwards.
        router.pendingConversation = nil
        await settle()
        #expect(router.pendingConversation == nil)
    }

    @Test("a second tap on the same person is ignored, and one on another person is not")
    func dedupesPerPeer() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        router.open(with: "peer-1")
        router.open(with: "peer-2")

        // Both people are in flight; only the repeat tap was dropped.
        #expect(router.isOpening("peer-1"))
        #expect(router.isOpening("peer-2"))
        #expect(router.isOpening("peer-3") == false)

        opener.answer(.success("channel-9"))
        await settle()

        // A double tap must not produce two navigations — but a tap on a *different*
        // person is a different request, and dropping it made the Message action silently
        // dead app-wide for as long as an unrelated open took to answer. Asserted as a set
        // because two in-flight opens reach the stub on the concurrent executor, so which
        // records itself first is not this test's claim.
        #expect(Set(opener.peers) == ["peer-1", "peer-2"])
        #expect(opener.peers.count == 2)
        #expect(router.pendingConversation?.channelID == "channel-9")
    }

    @Test("a failure surfaces a sentence and leaves nothing to navigate to")
    func surfacesFailure() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        opener.answer(.failure(DirectMessageError.rejected(.restricted("not a relay member"))))
        await settle()

        #expect(!router.isOpening)
        #expect(router.pendingConversation == nil)
        #expect(router.failure == "The relay would not open this conversation for you.")

        // And the router is usable again afterwards — a failure is not a dead end.
        router.failure = nil
        opener.answer(.success("channel-2"))
        router.open(with: "peer-1")
        await settle()
        #expect(router.pendingConversation?.channelID == "channel-2")
    }

    @Test("a success clears an unacknowledged failure, so it cannot surface later")
    func successClearsStaleFailure() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: "peer-1")
        opener.answer(.failure(DirectMessageError.publishFailed(.connectionLost)))
        await settle()
        #expect(router.failure != nil)

        // Nobody acknowledged the alert — the sheet that raised it is long gone. The next
        // successful open must not leave a stale failure still asking to be presented, on
        // whatever surface happens to be up when the navigation lands.
        opener.answer(.success("channel-3"))
        router.open(with: "peer-2")
        await settle()

        #expect(router.pendingConversation?.channelID == "channel-3")
        #expect(router.failure == nil)
    }

    @Test("opening a conversation leaves exactly one instance of it, on top")
    func conversationRouteDedupesTheStack() {
        let dm = ConversationRoute(channel: Self.row("dm-1"), knownPeer: "peer-1")
        let room = ConversationRoute(channel: Self.row("room-1"))

        #expect(dm.pushed(onto: []).map(\.channel.id) == ["dm-1"])

        // The reachable defect this rule exists for: inside a DM every row carries the
        // peer's face, whose profile sheet offers Message — which opens the conversation the
        // reader is already in. An unconditional append stacked it on itself, so backing out
        // of a DM went through an identical DM.
        #expect(dm.pushed(onto: [dm]).map(\.channel.id) == ["dm-1"])
        // Already on top is left untouched rather than re-pushed, so nothing animates.
        #expect(dm.pushed(onto: [room, dm]).map(\.channel.id) == ["room-1", "dm-1"])
        // Deeper in the stack it moves to the top instead of appearing twice.
        #expect(dm.pushed(onto: [dm, room]).map(\.channel.id) == ["room-1", "dm-1"])
        // A different conversation still pushes.
        #expect(room.pushed(onto: [dm]).map(\.channel.id) == ["dm-1", "room-1"])
    }

    /// The minimum row a pushed conversation needs, matching what
    /// `ChannelListView.conversationRow(for:)` synthesises for a channel the sidebar has
    /// not seen yet.
    private static func row(_ id: String) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: nil,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
        )
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
