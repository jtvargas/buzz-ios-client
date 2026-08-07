import Foundation
@testable import Hive
import Testing

@MainActor
@Suite("Composer send-time uploads", .timeLimit(.minutes(1)))
struct ComposerSendTimeUploadTests {
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

    static func prepare(_ count: Int, in model: ComposerAttachmentsModel) async {
        model.add((0 ..< count).map {
            StubPickedItem(data: TestPicture.png(), suggestedFilename: "pic-\($0)")
        })
        await waitUntil { !model.isAttaching }
    }

    @Test("a partial failure retries only the row that failed")
    func partialFailureSkipsSuccessfulUploadsOnRetry() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })
        await Self.prepare(3, in: model)

        let firstSend = Task { await model.prepareForSend() }
        await Self.waitUntil { await uploader.parkedCount == 3 }
        await uploader.releaseOne(.failure(.rejectedByPolicy))
        await uploader.releaseAll()
        #expect(await !firstSend.value)
        #expect(model.readyDescriptors.count == 2)
        #expect(await uploader.requests.count == 3)

        let retry = Task { await model.prepareForSend() }
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()

        #expect(await retry.value)
        #expect(model.readyDescriptors.count == 3)
        #expect(await uploader.requests.count == 4)
    }

    @Test("no more than three send-time uploads run at once")
    func concurrencyIsCapped() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })
        let picked = ComposerAttachmentsModel.selectionLimit
        await Self.prepare(picked, in: model)

        let sending = Task { await model.prepareForSend() }
        await Self.waitUntil {
            await uploader.parkedCount == ComposerAttachmentsModel.maxConcurrentUploads
        }
        #expect(await uploader.parkedCount == ComposerAttachmentsModel.maxConcurrentUploads)

        while model.isUploadingForSend {
            await uploader.releaseAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(await sending.value)
        #expect(model.readyDescriptors.count == picked)
        #expect(await uploader.peakConcurrent <= ComposerAttachmentsModel.maxConcurrentUploads)
    }
}
