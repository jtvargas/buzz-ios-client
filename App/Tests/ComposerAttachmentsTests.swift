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
    @MainActor
    private final class UploaderSlot {
        var value: (any MediaUploading)?
    }

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

        model.add([Self.item()])

        // The tile is there before the network has been touched.
        #expect(model.attachments.count == 1)
        #expect(model.isAttaching)
        #expect(!model.hasSendableContent)

        // Waited on the upload being *parked*, not on the preview appearing. The model
        // applies the preview before it calls `upload`, and the call it then makes is
        // spawned unstructured — so a preview says only that the work is coming, and
        // `releaseAll()` reached for on that signal can release an empty set and leave the
        // upload parked for the rest of the test. Every other wait in this suite already
        // uses `parkedCount`; this was the one that did not, and it is the one that failed.
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { !model.isAttaching }

        #expect(model.hasSendableContent)
        #expect(model.readyDescriptors.count == 1)
        // Asserted rather than waited on, now that the wait above is about the upload. The
        // model writing the preview onto the row is what draws the strip thumbnail while
        // the upload is still in flight, and nothing else in this target covers it —
        // `ComposerImagePreparationTests` covers `prepare()` producing one, not the model
        // applying it. As a wait it never guarded anything: the bounded helper falls
        // through, so a preview that never arrived cost five seconds and still passed.
        #expect(model.attachments.first?.preview != nil)
        // A PNG is a format the relay stores, so it went up as it was.
        let requests = await uploader.requests
        #expect(requests.map(\.mimeType) == ["image/png"])
    }

    /// The flag the send gate is built on — its effect on an actual send is
    /// asserted in ``ComposerAttachmentSendTests``.
    @Test("the in-flight window opens on the pick and closes on the answer")
    func attachingWindow() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { uploader })

        model.add([StubPickedItem(data: Data("%PDF-1.7 not a picture".utf8))])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "That file isn't a picture.")
        let requests = await uploader.requests
        #expect(requests.isEmpty)
    }

    /// A full composer's worth picked at once must not become five simultaneous
    /// conversions — each one holds a full-size bitmap while it runs.
    @Test("no more than three uploads run at once")
    func concurrencyIsCapped() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })
        let picked = ComposerAttachmentsModel.selectionLimit

        model.add((0 ..< picked).map { _ in Self.item() })
        #expect(model.attachments.count == picked)

        await Self.waitUntil { await uploader.parkedCount == ComposerAttachmentsModel.maxConcurrentUploads }
        let parked = await uploader.parkedCount
        #expect(parked == ComposerAttachmentsModel.maxConcurrentUploads)

        // Drain the rest, releasing whatever is parked until every one has landed.
        while model.isAttaching {
            await uploader.releaseAll()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        #expect(model.readyDescriptors.count == picked)
        let peak = await uploader.peakConcurrent
        #expect(peak <= ComposerAttachmentsModel.maxConcurrentUploads)
    }

    @Test("taking attachments for a send empties the composer")
    func takeForSendEmpties() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })

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
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })
        let descriptor = StubUploader.descriptor(key: "one", mimeType: "image/png", size: 10)

        model.restore([descriptor])

        #expect(model.readyDescriptors == [descriptor])
        #expect(!model.isAttaching)
    }

    @Test("with no session mounted, a pick says so rather than doing nothing")
    func noUploaderIsReported() async throws {
        let model = ComposerAttachmentsModel(uploader: { nil })

        model.add([Self.item()])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.uploadError == "This conversation isn't ready for pictures yet — try again in a moment.")
    }

    /// The conversation model is allowed to exist before the session finishes mounting.
    /// The provider must therefore be read when the author picks, not when the screen is
    /// constructed — this is the regression seam for the stale-uploader defect.
    @Test("a screen built before its session mounts can attach once the uploader exists")
    func uploaderIsResolvedAtPickTime() async throws {
        let slot = UploaderSlot()
        let model = ComposerAttachmentsModel(uploader: { slot.value })

        #expect(slot.value == nil)

        let uploader = StubUploader()
        slot.value = uploader
        model.add([Self.item()])

        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { !model.isAttaching }

        #expect(model.hasSendableContent)
        #expect(model.uploadError == nil)
    }

    // MARK: - The cap

    @Test("more pictures than the cap keeps the first five and says so")
    func capIsEnforcedOnAdd() async throws {
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })

        model.add((0 ..< 8).map { _ in Self.item() })

        #expect(model.attachments.count == ComposerAttachmentsModel.selectionLimit)
        #expect(model.uploadError == "You can attach 5 pictures at a time.")
        #expect(model.remainingCapacity == 0)
    }

    /// The case the picker's own limit cannot see: it counts one visit, not what is already
    /// on the bar. A paste comes through the same door and would otherwise walk past five.
    @Test("the cap counts what is already attached, not one visit to the picker")
    func capSpansSeparateAdds() async throws {
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })

        model.add((0 ..< 3).map { _ in Self.item() })
        model.add((0 ..< 3).map { _ in Self.item() })

        #expect(model.attachments.count == 5)
        #expect(model.uploadError == "You can attach 5 pictures at a time.")
    }

    @Test("a composer with room takes everything offered and says nothing")
    func underTheCapIsSilent() async throws {
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })

        model.add((0 ..< 4).map { _ in Self.item() })

        #expect(model.attachments.count == 4)
        #expect(model.uploadError == nil)
        #expect(model.remainingCapacity == 1)
    }

    // MARK: - The error's own lifetime

    /// The owner's ask: a composer still showing a complaint about a pick from five minutes
    /// ago is noise. Also asserts ``barRevision`` comes back down, because the bar's height
    /// is what the scaffold reads — an error that vanished visually while still declaring
    /// its height would leave a gap over the conversation.
    @Test("an error takes itself off screen after its time")
    func errorClearsItself() async {
        let model = ComposerAttachmentsModel(errorDuration: .milliseconds(50))
        let quiet = model.barRevision

        model.reportAtCapacity()
        #expect(model.uploadError != nil)
        #expect(model.barRevision != quiet)

        await Self.waitUntil { model.uploadError == nil }

        #expect(model.uploadError == nil)
        #expect(model.barRevision == quiet)
    }

    /// The case that makes this a funnel rather than a timer per call site: tapping a full
    /// composer twice. If the second error inherited what was left of the first one's
    /// countdown it would flash away early, and the reader would blame the tap.
    ///
    /// The two dwells here are the assertion, not a settling delay — this proves a clear
    /// did *not* happen at a moment, and polling for absence returns instantly and proves
    /// nothing. Do not replace them with a poll.
    @Test("a second error gets its own countdown, not the remains of the first")
    func secondErrorRestartsTheCountdown() async {
        let model = ComposerAttachmentsModel(errorDuration: .milliseconds(500))

        model.reportAtCapacity()
        try? await Task.sleep(for: .milliseconds(400))
        model.reportAtCapacity()

        // 700ms in: 200ms past the first error's deadline, 300ms short of the second's.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(model.uploadError != nil)

        await Self.waitUntil { model.uploadError == nil }
        #expect(model.uploadError == nil)
    }

    /// A pick landing is the other way an error goes, and it has to stop the countdown as
    /// well as blank the text — otherwise the *next* error is cleared by this one's timer.
    @Test("a countdown stopped by a successful pick cannot clear a later error")
    func clearingStopsTheCountdown() async {
        let model = ComposerAttachmentsModel(
            uploader: { StubUploader() },
            errorDuration: .milliseconds(300)
        )

        model.reportAtCapacity()
        model.add([Self.item()])
        #expect(model.uploadError == nil)

        // Past the first countdown's deadline, so it has fired by now if it survived.
        try? await Task.sleep(for: .milliseconds(400))
        model.reportAtCapacity()
        try? await Task.sleep(for: .milliseconds(100))

        #expect(model.uploadError != nil)
    }

    // MARK: - The deadlines

    /// The owner's report: attach several and one spins for ever.
    ///
    /// The cause was that nothing bounded `loadTransferable`, which on an iCloud-backed photo
    /// waits for a download. A tile that never resolves also holds ``isAttaching`` true, so
    /// the whole composer is stuck behind it — which is why this asserts the send gate
    /// reopens, not merely that the tile went.
    @Test("a source that never answers gives up instead of spinning for ever")
    func sourceDeadlineFires() async throws {
        let model = ComposerAttachmentsModel(
            uploader: { StubUploader() },
            sourceDeadline: .milliseconds(40)
        )

        model.add([StubPickedItem(data: Data(), neverReturns: true)])
        #expect(model.isAttaching)

        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(!model.isAttaching, "the send gate is still held shut by a picture that gave up")
        #expect(model.uploadError == "That picture took too long to load — it may still be in iCloud.")
    }

    /// The other half: the relay accepts the connection and stops answering. `URLSession`'s
    /// own resource timeout is seven days by default, so without this the tile spins there too.
    @Test("a relay that never answers gives up instead of spinning for ever")
    func uploadDeadlineFires() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(
            uploader: { uploader },
            uploadDeadline: .milliseconds(40)
        )

        // Parked and never released — the stub's whole purpose.
        model.add([Self.item()])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(!model.isAttaching)
        #expect(model.uploadError == "That picture took too long to upload.")
    }

    /// The race's own contract, which every deadline above rests on: the loser answers too —
    /// a cancelled fetch throws `CancellationError` a moment after the deadline has already
    /// spoken — and a second answer must be dropped rather than resume the waiter twice.
    /// Resuming a continuation twice does not fail a test, it kills the bundle.
    @Test("only the first answer of a race is heard")
    func laterAnswersAreDropped() async throws {
        let race = FirstAnswer<Int>()

        await race.settle(.success(1))
        await race.settle(.success(2))
        await race.settle(.failure(ComposerAttachmentError.uploadTimedOut))

        #expect(try await race.value().get() == 1)
    }

    /// A deadline that fires on a picture that would have succeeded is worse than no deadline,
    /// so this pins the other direction.
    @Test("an upload that lands inside the deadline is unaffected")
    func deadlineDoesNotFireOnASuccess() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader }, uploadDeadline: .seconds(30))

        model.add([Self.item()])
        await Self.waitUntil { await uploader.parkedCount == 1 }
        await uploader.releaseAll()
        await Self.waitUntil { !model.isAttaching }

        #expect(model.hasSendableContent)
        #expect(model.uploadError == nil)
    }

    /// What the conversation is told, so its bottom inset can move with the bar —
    /// ``ConversationScaffold/composerRevision``. The rectangles this ends up
    /// producing on a screen are ``ComposerGrowthTests``' to assert; this pins the
    /// declaration itself, and specifically the two ways a count would have been
    /// wrong.
    @Test("the bar declares a height change on the first picture and on the last, never in between")
    func barRevisionFollowsTheBarsHeight() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })
        let resting = model.barRevision

        model.add([Self.item()])
        let withOne = model.barRevision
        #expect(withOne != resting, "the strip appearing did not declare a height change")

        // The strip scrolls sideways rather than wrapping, so it is exactly as tall
        // with three pictures as with one — and the conversation must not be told
        // its inset moved when it did not.
        model.add([Self.item(), Self.item()])
        #expect(model.barRevision == withOne, "a second picture declared a height change it did not cause")

        for attachment in model.attachments { model.remove(attachment.id) }
        #expect(model.barRevision == resting, "the strip going away did not declare a height change")
    }

    /// The other half of the same contract, and the one a count could not have
    /// expressed: a failed upload takes the tile away *and* puts a line of text
    /// under the strip, so the bar changes height twice over with the attachment
    /// list empty at both ends.
    @Test("a failed upload declares its own height change")
    func barRevisionCoversTheErrorLine() async throws {
        let model = ComposerAttachmentsModel(uploader: { nil })
        let resting = model.barRevision

        model.add([Self.item()])
        await Self.waitUntil { model.uploadError != nil }

        #expect(model.attachments.isEmpty)
        #expect(model.barRevision != resting, "the error line did not declare a height change")
    }
}
