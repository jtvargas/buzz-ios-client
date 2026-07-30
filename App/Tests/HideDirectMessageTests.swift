import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

/// The states around hiding a direct message: in flight, refused, and what the reader is
/// told. The rule that matters for correctness is that a second press on the *same* row
/// while its hide is on the wire does not send a second command — and that a refusal is
/// still reportable after the row it was pressed on has gone.
@MainActor
@Suite("Hide direct message", .timeLimit(.minutes(1)))
struct HideDirectMessageTests {
    /// A controllable hider: it records what it was asked to hide and answers on demand,
    /// so a test can observe the in-flight state rather than racing it.
    private final class StubHider: DirectMessageHiding, @unchecked Sendable {
        private let lock = NSLock()
        private var _channels: [String] = []
        private var _result: Result<Void, any Error>?

        var channels: [String] {
            lock.withLock { _channels }
        }

        func answer(_ result: Result<Void, any Error>) {
            lock.withLock { _result = result }
        }

        func hideDirectMessage(_ channelID: String) async throws {
            lock.withLock { _channels.append(channelID) }
            while true {
                if let result = lock.withLock({ _result }) {
                    return try result.get()
                }
                // `try`, not `try?`: swallowing cancellation here would leave a stub that
                // cannot be cancelled, so a test whose model outlived it would spin to the
                // suite's time limit rather than ending with it.
                try await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    private func settle() async {
        // A real sleep, not `Task.yield()`: the model hops to its own task and the stub
        // sleeps, so yielding can return before either has run.
        try? await Task.sleep(for: .milliseconds(60))
    }

    @Test("a successful hide sends exactly one command and reports nothing")
    func hidesOnce() async {
        let hider = StubHider()
        let model = HideDirectMessageModel(hider: hider)

        model.hide("dm-1")
        await settle()
        #expect(model.isHiding("dm-1"))

        hider.answer(.success(()))
        await settle()
        #expect(!model.isHiding("dm-1"))
        #expect(model.failure == nil)
        #expect(hider.channels == ["dm-1"])
    }

    @Test("a second press while the first is in flight sends nothing")
    func guardsAgainstASecondPress() async {
        let hider = StubHider()
        let model = HideDirectMessageModel(hider: hider)

        model.hide("dm-1")
        await settle()
        model.hide("dm-1")
        await settle()
        #expect(hider.channels == ["dm-1"])

        hider.answer(.success(()))
        await settle()
        // And once it has answered, the same row may be hidden again — the guard is one
        // press, not one lifetime. (Re-opening the DM clears the hide relay-side, so this
        // is a reachable sequence, not a hypothetical one.)
        model.hide("dm-1")
        await settle()
        #expect(hider.channels == ["dm-1", "dm-1"])
    }

    @Test("one row's hide does not block another's")
    func guardIsPerConversation() async {
        let hider = StubHider()
        let model = HideDirectMessageModel(hider: hider)

        model.hide("dm-1")
        model.hide("dm-2")
        await settle()
        #expect(hider.channels.sorted() == ["dm-1", "dm-2"])
        #expect(model.isHiding("dm-1"))
        #expect(model.isHiding("dm-2"))
    }

    @Test("a refusal is reported in the relay's own words and clears the in-flight mark")
    func reportsRefusal() async {
        let hider = StubHider()
        let model = HideDirectMessageModel(hider: hider)

        model.hide("dm-1")
        await settle()
        hider.answer(.failure(DirectMessageError.rejected(.invalid("channel is not a DM"))))
        await settle()

        #expect(!model.isHiding("dm-1"))
        #expect(model.failure == "The relay refused to hide it: channel is not a DM")
    }

    @Test("a later success clears an unacknowledged failure")
    func successClearsAStaleFailure() async {
        let hider = StubHider()
        let model = HideDirectMessageModel(hider: hider)

        model.hide("dm-1")
        await settle()
        hider.answer(.failure(DirectMessageError.publishFailed(.connectionLost)))
        await settle()
        #expect(model.failure != nil)

        hider.answer(.success(()))
        model.hide("dm-2")
        await settle()
        #expect(model.failure == nil)
    }

    /// The two refusals a reader can actually provoke both carry their explanation in
    /// prose, and both would be thrown away by a summary. `forbidden:` is not a NIP-01
    /// prefix at all, so it arrives whole as ``OKReason/unspecified(_:)``.
    @Test(
        "the reader-facing sentence",
        arguments: [
            (
                DirectMessageError.rejected(.unspecified("forbidden: not a member of this DM")),
                "The relay refused to hide it: forbidden: not a member of this DM"
            ),
            (
                DirectMessageError.rejected(.invalid("bad channel_id format")),
                "The relay refused to hide it: bad channel_id format"
            ),
            (
                DirectMessageError.rejected(.restricted("")),
                "The relay would not hide this conversation for you."
            ),
            (
                DirectMessageError.rejected(.rateLimited("slow down")),
                "The relay is rate limiting. Wait a moment and try again."
            ),
            (
                DirectMessageError.rejected(.error("db hide_dm")),
                "The relay refused to hide it."
            ),
            (
                DirectMessageError.publishFailed(.timedOut),
                "No connection to the relay. Try again once it reconnects."
            ),
        ]
    )
    func message(error: DirectMessageError, sentence: String) {
        #expect(HideDirectMessageModel.message(for: error) == sentence)
    }

    @Test("an error this path cannot produce still says something useful")
    func unknownErrorHasASentence() {
        struct Nothing: Error {}
        #expect(
            HideDirectMessageModel.message(for: Nothing())
                == "Could not hide the conversation. Try again."
        )
    }
}
