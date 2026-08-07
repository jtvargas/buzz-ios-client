import BuzzKit
import Foundation
@testable import Hive
import NostrCore
import Testing

private enum TestEnqueueFailure: Error {
    case signerUnavailable
}

/// Parks before throwing so a test can add a new attachment in the exact window
/// between `takeForSend()` and restoration.
private actor ThrowingSender: MessageSending {
    enum Failure: Sendable {
        case generic
        case contentTooLarge
    }

    let failure: Failure
    private(set) var isWaiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    init(failure: Failure) {
        self.failure = failure
    }

    func enqueue(
        kind _: EventKind,
        content _: String,
        in _: String,
        tags _: [[String]],
        maxContentBytes _: Int
    ) async throws -> OutboxEntry {
        isWaiting = true
        await withCheckedContinuation { (waiting: CheckedContinuation<Void, Never>) in
            continuation = waiting
        }
        switch failure {
        case .generic:
            throw TestEnqueueFailure.signerUnavailable
        case .contentTooLarge:
            throw OutboxError.contentTooLarge(bytes: 70_000, limit: 65_536)
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }

    func retry(_: String) async throws {}
    func discard(_: String) async throws {}
}

@MainActor
@Suite("Composer enqueue failure restore", .timeLimit(.minutes(1)))
struct ComposerEnqueueFailureTests {
    static func waitUntil(
        _ condition: @MainActor () async -> Bool,
        within seconds: Double = 5
    ) async {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    static func attach(to model: ComposerAttachmentsModel) async {
        model.add([
            StubPickedItem(data: TestPicture.png(), suggestedFilename: "pic-0"),
        ])
        await waitUntil { !model.isAttaching }
    }

    @Test("a generic enqueue failure restores the channel draft and prepends its media")
    func genericFailureRestoresChannel() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = ThrowingSender(failure: .generic)
        let uploader = StubUploader()
        let model = ChannelTimelineModel(
            channel: "room-1", store: store, sender: sender, uploader: { uploader }
        )
        await Self.attach(to: model.attachments)
        model.mentionDraft = MentionDraft(text: "keep this")

        model.send()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { await sender.isWaiting }

        model.attachments.add([StubPickedItem(data: TestPicture.png())])
        await Self.waitUntil { !model.attachments.isAttaching }
        await sender.release()
        await Self.waitUntil { model.sendError != nil }

        #expect(model.mentionDraft.text == "keep this")
        #expect(model.sendError == "Couldn't send that message.")
        #expect(model.attachments.attachments.count == 2)
        #expect(model.attachments.attachments.first?.descriptor?.url.contains("pic-0") == true)
        #expect(model.attachments.attachments.last?.descriptor == nil)
    }

    @Test("content-too-large restores a thread reply and its media")
    func contentTooLargeRestoresThread() async throws {
        let temp = TempStore()
        defer { temp.remove() }
        let store = try temp.open()
        let sender = ThrowingSender(failure: .contentTooLarge)
        let uploader = StubUploader()
        let model = ThreadModel(
            root: "root-1",
            channel: "room-1",
            store: store,
            sender: sender,
            opener: StubThreadOpener(store: store, events: []),
            uploader: { uploader },
            selfPubkey: nil
        )
        await Self.attach(to: model.attachments)
        model.mentionDraft = MentionDraft(text: "keep this reply")

        model.sendReply()
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { await sender.isWaiting }
        await sender.release()
        await Self.waitUntil { model.sendError != nil }

        #expect(model.mentionDraft.text == "keep this reply")
        #expect(model.sendError == "Reply is too large (70000 bytes; limit 65536).")
        #expect(model.attachments.readyDescriptors.count == 1)
    }
}
