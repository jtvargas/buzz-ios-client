import BuzzKit
import Foundation
@testable import Hive
import Testing
import UIKit

/// What the composer does with a picture between picking it and sending it.
///
/// Local preparation remains in the composer; send transfers exact scrubbed bytes
/// to the durable outbox staging path.
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

    static func prepare(_ count: Int, in model: ComposerAttachmentsModel) async {
        model.add((0 ..< count).map { Self.item("pic-\($0)") })
        await waitUntil { !model.isAttaching }
    }

    @Test("a picked photo is scrubbed locally without uploading")
    func pickPreparesWithoutUploading() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })

        model.add([Self.item()])
        #expect(model.attachments.count == 1)
        #expect(model.isAttaching)
        #expect(!model.hasSendableContent)
        await Self.waitUntil { !model.isAttaching }

        #expect(model.hasSendableContent)
        #expect(model.attachments.first?.localPayload != nil)
        #expect(model.attachments.first?.preview != nil)
        #expect(await uploader.requests.isEmpty)
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

    @Test("taking attachments for a send empties the composer")
    func takeForSendEmpties() async throws {
        let uploader = StubUploader()
        let model = ComposerAttachmentsModel(uploader: { uploader })

        await Self.prepare(2, in: model)
        let taken = try #require(model.takeForSend())
        #expect(taken.count == 2)
        #expect(model.attachments.isEmpty)
        #expect(!model.hasSendableContent)
        // A second send carries nothing — the pictures went with the first.
        #expect(try #require(model.takeForSend()).isEmpty)
    }

    /// A send refused before it left the device gives the text back; it has to give
    /// the pictures back too, or an over-ceiling message loses them silently.
    @Test("a refused send puts the pictures back")
    func restoreAfterRefusal() async throws {
        let model = ComposerAttachmentsModel(uploader: { StubUploader() })
        await Self.prepare(1, in: model)
        let payload = try #require(model.attachments.first?.localPayload)

        _ = model.takeForSend()
        model.restore([payload])

        #expect(model.attachments.first?.localPayload == payload)
        #expect(model.attachments.first?.preview != nil)
        #expect(!model.isAttaching)
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

    /// The race's own contract, which every deadline above rests on: the loser answers too —
    /// a cancelled fetch throws `CancellationError` a moment after the deadline has already
    /// spoken — and a second answer must be dropped rather than resume the waiter twice.
    /// Resuming a continuation twice does not fail a test, it kills the bundle.
    @Test("only the first answer of a race is heard")
    func laterAnswersAreDropped() async throws {
        let race = FirstAnswer<Int>()

        await race.settle(.success(1))
        await race.settle(.success(2))
        await race.settle(.failure(ComposerAttachmentError.sourceTimedOut))

        #expect(try await race.value().get() == 1)
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

}
