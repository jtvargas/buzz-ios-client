import BuzzKit
import Foundation
@testable import Hive
import Testing
import UIKit

/// What the composer does with a picture between picking it and sending it.
///
/// The interesting behaviour is all in the window *during* an upload — send
/// refused, a tile removed, a refusal surfaced — so ``StubUploader`` parks every
/// upload until this suite releases it. A double that answered immediately would
/// close that window before anything could be asserted in it.
@MainActor
@Suite("Composer attachments", .timeLimit(.minutes(1)))
struct ComposerAttachmentsTests {
    /// Spins until `condition` holds or the deadline passes, so a test never waits
    /// on a fixed sleep for work that crosses actors.
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

    static func item(_ filename: String? = nil) -> StubPickedItem {
        StubPickedItem(data: TestPicture.png(), suggestedFilename: filename)
    }

    @Test("a picked photo uploads and becomes an attachment")
    func pickUploadsAndLands() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item()])

        // The tile is there before the network has been touched.
        #expect(model.attachments.count == 1)
        #expect(model.isAttaching)
        #expect(!model.hasSendableContent)

        await Self.waitUntil { model.attachments.first?.preview != nil }
        await uploader.releaseAll()
        await Self.waitUntil { !model.isAttaching }

        #expect(model.hasSendableContent)
        #expect(model.readyDescriptors.count == 1)
        // A PNG is a format the relay stores, so it went up as it was.
        let requests = await uploader.requests
        #expect(requests.map(\.mimeType) == ["image/png"])
    }

    /// The flag the send gate is built on — its effect on an actual send is
    /// asserted in ``ComposerAttachmentSendTests``.
    @Test("the in-flight window opens on the pick and closes on the answer")
    func attachingWindow() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item()])
        #expect(model.isAttaching)

        // Wait for the upload to actually arrive before releasing it: the pick is
        // decoded and possibly converted first, so releasing straight away releases
        // nothing and the upload parks for good.
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { !model.isAttaching }
        #expect(!model.isAttaching)
    }

    /// The rule that makes a photo message possible at all.
    @Test("an uploaded picture alone is enough to send")
    func pictureAloneIsSendable() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item()])
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { model.hasSendableContent }

        #expect(model.hasSendableContent)
    }

    /// The defect this guards is the one the Drafts screen already taught: a row
    /// deleted while its write was in flight came back when the write landed.
    @Test("a tile removed mid-upload does not come back when the upload lands")
    func removalDuringUploadSticks() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item()])
        let id = try #require(model.attachments.first?.id)
        await Self.waitUntil { await uploader.parkedCount == 1 }

        model.remove(id)
        #expect(model.attachments.isEmpty)

        await uploader.releaseAll()
        // Give the landed upload every chance to write itself back in.
        for _ in 0 ..< 50 { await Task.yield() }
        #expect(model.attachments.isEmpty)
        #expect(!model.hasSendableContent)
    }

    @Test("a refused upload leaves no tile and says why")
    func refusedUploadSurfaces() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item()])
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll(.failure(.rejectedByPolicy))
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "The relay wouldn't store that picture.")
    }

    @Test("a pick that yields no bytes never reaches the uploader")
    func failedLoadNeverUploads() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([StubPickedItem(data: Data(), failsToLoad: true)])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        let requests = await uploader.requests
        #expect(requests.isEmpty)
    }

    /// Bytes ImageIO will not open are refused on this device rather than uploaded
    /// to be refused by the relay.
    @Test("something that is not a picture is refused before it is uploaded")
    func notAPictureIsRefusedLocally() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([StubPickedItem(data: Data("%PDF-1.7 not a picture".utf8))])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "That file isn't a picture.")
        let requests = await uploader.requests
        #expect(requests.isEmpty)
    }

    /// Ten pictures picked at once must not become ten simultaneous conversions —
    /// each one holds a full-size bitmap while it runs.
    @Test("no more than three uploads run at once")
    func concurrencyIsCapped() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add((0 ..< 8).map { _ in Self.item() })
        #expect(model.attachments.count == 8)

        await Self.waitUntil { await uploader.parkedCount == ComposerAttachmentsModel.maxConcurrentUploads }
        let parked = await uploader.parkedCount
        #expect(parked == ComposerAttachmentsModel.maxConcurrentUploads)

        // Drain the rest, releasing whatever is parked until all eight have landed.
        while model.isAttaching {
            await uploader.releaseAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.readyDescriptors.count == 8)
        let peak = await uploader.peakConcurrent
        #expect(peak <= ComposerAttachmentsModel.maxConcurrentUploads)
    }

    @Test("taking attachments for a send empties the composer")
    func takeForSendEmpties() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: uploader)

        model.add([Self.item(), Self.item()])
        while model.isAttaching {
            await uploader.releaseAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        let taken = model.takeForSend()
        #expect(taken.count == 2)
        #expect(model.attachments.isEmpty)
        #expect(!model.hasSendableContent)
        // A second send carries nothing — the pictures went with the first.
        #expect(model.takeForSend().isEmpty)
    }

    /// A send refused before it left the device gives the text back; it has to give
    /// the pictures back too, or an over-ceiling message loses them silently.
    @Test("a refused send puts the pictures back")
    func restoreAfterRefusal() async throws {
        let model = ComposerAttachmentsModel(uploader: StubUploader())
        let descriptor = StubUploader.descriptor(key: "one", mimeType: "image/png", size: 10)

        model.restore([descriptor])

        #expect(model.readyDescriptors == [descriptor])
        #expect(!model.isAttaching)
    }

    @Test("with no relay configured, a pick says so rather than doing nothing")
    func noUploaderIsReported() async throws {
        let model = ComposerAttachmentsModel(uploader: nil)

        model.add([Self.item()])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "Not connected to a relay yet.")
    }
}
