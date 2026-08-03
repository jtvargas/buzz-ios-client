import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The states around opening a direct message: in flight, navigable, failed — the one rule
/// that matters for correctness, which is that a second tap on the *same conversation* while
/// its open is in flight does not send a second one, and what the navigation surface then
/// does with the result.
///
/// "The same conversation" is a whole participant set and not one person: two groups that
/// share somebody are two conversations, and a guard keyed on a person would have the first
/// of them silently swallow the second.
@MainActor
@Suite("Direct message router", .timeLimit(.minutes(1)))
struct DirectMessageRouterTests {
    /// A controllable opener: it records what it was asked for and answers on demand, so
    /// a test can observe the in-flight state rather than racing it.
    private final class StubOpener: DirectMessageOpening, @unchecked Sendable {
        private let lock = NSLock()
        private var _opens: [[String]] = []
        private var _result: Result<String, any Error>?

        /// Every open the router actually sent, in the order the stub received them.
        var opens: [[String]] {
            lock.withLock { _opens }
        }

        func answer(_ result: Result<String, any Error>) {
            lock.withLock { _result = result }
        }

        func openDirectMessage(with peers: [String]) async throws -> String {
            lock.withLock { _opens.append(peers) }
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
        #expect(router.pendingConversation == OpenedConversation(channelID: "channel-9", peers: ["peer-1"]))
        #expect(router.failure == nil)
        #expect(opener.opens == [["peer-1"]])

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
        #expect(Set(opener.opens) == [["peer-1"], ["peer-2"]])
        #expect(opener.opens.count == 2)
        #expect(router.pendingConversation?.channelID == "channel-9")
    }

    @Test("two groups that share a person do not block each other")
    func overlappingGroupsBothOpen() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: ["ada", "bo"])
        router.open(with: ["ada", "cy"])
        // And the one that *is* the same conversation, still dropped.
        router.open(with: ["ada", "bo"])

        #expect(router.isOpening(["ada", "bo"]))
        #expect(router.isOpening(["ada", "cy"]))
        // Neither group is "Ada's open": a person is not a conversation, and a one-to-one
        // with Ada is a third, still untouched.
        #expect(router.isOpening("ada") == false)

        opener.answer(.success("channel-9"))
        await settle()

        #expect(Set(opener.opens) == [["ada", "bo"], ["ada", "cy"]])
        #expect(opener.opens.count == 2)
    }

    @Test("the same people named in another order, or another case, are one open")
    func participantSetIsOrderAndCaseInsensitive() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: ["ada", "bo", "cy"])
        router.open(with: ["CY", "Ada", "BO"])

        #expect(router.isOpening(["cy", "bo", "ada"]))
        opener.answer(.success("channel-9"))
        await settle()

        // One request on the wire. The guard key is the set, not the spelling of it — the
        // relay answers the same channel either way, so two would be two navigations to it.
        #expect(opener.opens == [["ada", "bo", "cy"]])
    }

    /// The property the guard key gets from folding through
    /// ``BuzzKit/SyncEngine/normalizedPubkey(_:)`` rather than lower-casing: two spellings
    /// of one identity are one conversation. A hand-rolled fold agrees with the wire in
    /// every test written against hex and disagrees the first time somebody passes an
    /// `npub1…` — a double tap that opens the same conversation twice.
    @Test("hex and npub for the same person are one open, not two")
    func mixedIdentifierFormsAreOneOpen() async throws {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)
        let ada = try #require(PublicKey(hex: String(repeating: "11", count: 32)))
        let bo = try #require(PublicKey(hex: String(repeating: "22", count: 32)))

        router.open(with: [ada.hex, bo.hex])
        router.open(with: [ada.npub, bo.hex])

        #expect(router.isOpening([bo.npub, ada.hex]))
        opener.answer(.success("channel-9"))
        await settle()

        #expect(opener.opens == [[ada.hex, bo.hex]])
    }

    @Test("a group carries all of its people into the conversation to navigate to")
    func groupOpenCarriesEveryPeer() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: ["ada", "bo", "cy"])
        opener.answer(.success("gdm-1"))
        await settle()

        // All three, in the order they were picked: they are what titles the conversation
        // until its roster lands (see ``EntityNames/conversation(for:knownPeers:)``), and a
        // group has no single person to name it by.
        #expect(router.pendingConversation == OpenedConversation(
            channelID: "gdm-1",
            peers: ["ada", "bo", "cy"]
        ))
    }

    @Test("an open with nobody in it is not sent")
    func emptyOpenIsRefused() async {
        let opener = StubOpener()
        let router = DirectMessageRouter(opener: opener)

        router.open(with: [])
        await settle()

        #expect(!router.isOpening)
        #expect(opener.opens.isEmpty)
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
        let dm = ConversationRoute(channel: Self.row("dm-1"), knownPeers: ["peer-1"])
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
        // The two the picker is built to prevent. They still earn their own sentence: the
        // generic one ends "Try again", and the same list would fail the same way.
        let nobody = DirectMessageRouter.message(for: DirectMessageError.noPeers)
        let overCap = DirectMessageRouter.message(
            for: DirectMessageError.tooManyPeers(
                count: SyncEngine.maxDirectMessagePeers + 1,
                limit: SyncEngine.maxDirectMessagePeers
            )
        )

        // Distinct, so a reader can tell "you are not allowed" from "you are offline".
        #expect(
            Set([restricted, invalidKey, malformed, offline, unknown, nobody, overCap]).count == 7
        )
        #expect(!restricted.isEmpty)
        // Never leaks a raw error description at the reader.
        #expect(!malformed.contains("{}"))
        // The cap the relay actually enforces, not a number spelled a second time here.
        #expect(overCap.contains("\(SyncEngine.maxDirectMessagePeers)"))
        #expect(!nobody.lowercased().contains("try again"))
    }
}
