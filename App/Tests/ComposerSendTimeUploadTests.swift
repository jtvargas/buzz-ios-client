import Foundation
@testable import Hive
import Testing

@MainActor
@Suite("Composer send-time staging", .timeLimit(.minutes(1)))
struct ComposerSendTimeUploadTests {
    static func payload(_ index: Int) -> ComposerAttachment.LocalPayload {
        .init(
            data: TestPicture.png(width: 40 + index, height: 24),
            mimeType: "image/png",
            filename: "pic-\(index).png"
        )
    }

    @Test("restore prepends the earlier send and trims the newest rows to the cap")
    func restoreTrimsNewestRows() {
        let model = ComposerAttachmentsModel()
        model.restore((0 ..< ComposerAttachmentsModel.selectionLimit).map(Self.payload))
        model.add([StubPickedItem(data: TestPicture.png(width: 80, height: 24))])

        model.restore([Self.payload(99)])

        #expect(model.attachments.count == ComposerAttachmentsModel.selectionLimit)
        #expect(model.attachments.first?.localPayload?.filename == "pic-99.png")
        #expect(model.uploadError == "You can attach up to 5 pictures.")
    }

    @Test("take returns local bytes and clears the composer before upload")
    func takeReturnsLocalPayloads() async throws {
        let model = ComposerAttachmentsModel()
        model.add([StubPickedItem(data: TestPicture.png(), suggestedFilename: "pic.png")])
        while model.isAttaching { await Task.yield() }

        let payloads = try #require(model.takeForSend())

        #expect(payloads.count == 1)
        #expect(payloads.first?.filename == "pic.png")
        #expect(model.attachments.isEmpty)
    }
}
