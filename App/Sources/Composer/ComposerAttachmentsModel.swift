import BuzzKit
import Foundation
import Observation
import UIKit

/// Resolves the session's uploader when prepared attachments are sent.
///
/// The provider is deliberately main-actor isolated: it reads the app's observable
/// environment, while ``MediaUploading`` remains `Sendable` for the actual request.
typealias MediaUploaderProvider = @MainActor @Sendable () -> (any MediaUploading)?

/// What the composer is carrying besides text.
///
/// Owned by the conversation model beside ``MentionDraft`` and cleared by the same
/// send, so a channel and each of its threads carry their own — picking a photo in
/// a thread cannot put it on the channel's next message.
///
/// # Three rules
///
/// 1. **Prepare on pick.** Loading, metadata scrubbing, colour conversion, and the
///    preview happen locally while the author is still composing.
/// 2. **Upload on send.** The relay is untouched until send is pressed, and every
///    upload finishes before the event is signed with its blob descriptors.
/// 3. **Retry only what failed.** A partial batch keeps successful descriptors;
///    failed rows return to local-ready bytes, so sending again cannot orphan a
///    second copy of a blob that already landed.
///
/// # What is not here
///
/// No persistence. Unlike the text draft — which survives leaving the conversation
/// (`ComposerDrafts`) — attachments are dropped when the model goes. Restoring
/// them would mean holding relay URLs for pictures the author may never send, and
/// deciding when those stop being theirs; the text draft has no such question.
@MainActor
@Observable
final class ComposerAttachmentsModel {
    /// Every attachment in the order it was picked, from local preparation onward.
    private(set) var attachments: [ComposerAttachment] = []

    /// Why the last preparation or send-time upload failed, for the banner above
    /// the strip. Cleared by the next attempt and by its own countdown.
    ///
    /// Written only through ``report(_:)`` and ``clearError()``. A direct assignment
    /// would leave whatever countdown is running pointed at it, and that countdown
    /// would then clear the *next* error early.
    private(set) var uploadError: String?

    /// Whether the live camera is occupying the panel above this composer's bar.
    private(set) var isCameraPresented = false

    /// At most this many preparations or uploads at once. Three bounds both the
    /// working bitmap memory at pick-time and relay bandwidth at send-time.
    static let maxConcurrentUploads = 3

    /// The most pictures one message may carry.
    ///
    /// Five, the owner's number. Enforced in ``add(_:)`` rather than only on the picker,
    /// because the picker is no longer the only way in — a paste arrives through the same
    /// door and would otherwise walk past the limit.
    static let selectionLimit = 5

    /// How long a source has to produce its bytes.
    ///
    /// This is the one that was missing. `loadTransferable` on a photo kept in iCloud has to
    /// fetch it first, and on a weak connection that wait has no end — the tile spins for
    /// ever and, because ``isAttaching`` gates send, the whole composer is stuck behind it.
    /// Generous, because a large photo coming down from iCloud legitimately takes a while;
    /// finite, because "for ever" is not a state an author can do anything about.
    static let sourceDeadline: Duration = .seconds(60)

    /// How long the relay has to accept the bytes.
    ///
    /// `URLSession`'s own resource timeout defaults to **seven days**, and its request
    /// timeout only fires when a connection goes completely silent — so a trickling upload is
    /// unbounded in practice. The uploader is handed a session with real ceilings
    /// (``AppEnvironment/makeMediaUploader(websocketURL:)``); this is the belt to that
    /// bracing, so a transport that somehow outlives its own timeout still ends here.
    ///
    /// Just outside the transport's own ceiling on purpose, so the error an author reads is
    /// the network naming its own failure rather than this giving up first. Long, for the
    /// reason set out there: killing a picture that was going to arrive is worse than the
    /// spinner, and the spinner has an X on it.
    ///
    /// It covers the upload and nothing else. The conversion between the two deadlines is
    /// deliberately left unbounded: it is CPU work that finishes, and a ceiling on it would
    /// mean an old phone re-encoding a large HEIC losing a picture that was going to arrive.
    static let uploadDeadline: Duration = .seconds(270)

    /// How long an error stays on screen before it takes itself off.
    ///
    /// The owner's ask: a composer carrying a stale complaint from five minutes ago
    /// is noise. Five seconds is long enough to read the longest one about twice;
    /// locally ready rows remain available after the banner clears.
    static let errorDuration: Duration = .seconds(5)

    /// The app environment can build this after a conversation screen exists, so this is
    /// resolved at send time rather than captured when the model is constructed. A send with
    /// no uploader fails with a reason rather than silently doing nothing.
    let uploader: MediaUploaderProvider

    /// The countdown clearing ``uploadError``, held so the next error can cancel it.
    ///
    /// Not observable: nothing renders it, and it changes on every error.
    @ObservationIgnored private var errorDismissal: Task<Void, Never>?

    /// The in-flight preparation batches, so a sign-out can stop them. Not
    /// observable: nothing renders them.
    @ObservationIgnored private var batches: [Task<Void, Never>] = []

    /// The deadlines this model actually uses.
    ///
    /// Instance rather than static so a test can prove the timeout *fires* — the shipped
    /// values are a minute and a half, and a suite that waited them out would be a suite
    /// nobody runs. The defaults are the shipped ones, so production reads exactly the
    /// constants documented above.
    private let sourceDeadline: Duration
    let uploadDeadline: Duration
    /// Injected for the same reason as the deadlines above: a suite that waited out the
    /// shipped five seconds per error would be a suite nobody runs.
    private let errorDuration: Duration

    init(
        uploader: @escaping MediaUploaderProvider = { nil },
        sourceDeadline: Duration = ComposerAttachmentsModel.sourceDeadline,
        uploadDeadline: Duration = ComposerAttachmentsModel.uploadDeadline,
        errorDuration: Duration = ComposerAttachmentsModel.errorDuration
    ) {
        self.uploader = uploader
        self.sourceDeadline = sourceDeadline
        self.uploadDeadline = uploadDeadline
        self.errorDuration = errorDuration
    }

    // MARK: - What the composer asks

    /// Whether anything is still being prepared locally — the send gate.
    var isAttaching: Bool { attachments.contains(where: \.isPreparing) }

    /// Whether a send-triggered upload batch is running.
    var isUploadingForSend: Bool { attachments.contains(where: \.isUploading) }

    /// The descriptors a message would carry, in pick order.
    var readyDescriptors: [BlobDescriptor] { attachments.compactMap(\.descriptor) }

    /// Whether there is anything to draw above the text field.
    var isEmpty: Bool { attachments.isEmpty }

    /// Changes exactly when these attachments make the composer a different height, and is
    /// otherwise meaningless — the conversation's declaration that its bottom inset is about
    /// to move. See ``ConversationScaffold/composerRevision``.
    ///
    /// Deliberately **not** the number of attachments. Ten pictures are the same 72-point row
    /// as one, because the strip scrolls sideways rather than wrapping, so a count would
    /// declare a height change on every pick after the first and never on the failure that
    /// swaps the strip for a line of red text. What actually moves the bar is those facts:
    /// whether there is a strip, an error line, or the inline camera panel.
    ///
    /// Computed so every path changing a height-bearing property declares the change.
    var barRevision: Int {
        (isEmpty ? 0 : 1) + (uploadError == nil ? 0 : 2) + (isCameraPresented ? 4 : 0)
            + (isUploadingForSend ? 8 : 0)
    }

    /// Whether these attachments alone are enough to justify a send — a picture
    /// with no words is a message.
    var hasSendableContent: Bool { attachments.contains(where: \.isReady) }

    // MARK: - Picking

    /// How many more this composer will take.
    var remainingCapacity: Int { max(0, Self.selectionLimit - attachments.count) }

    /// Says the composer is full, for a caller that declined to offer a picker at all.
    func reportAtCapacity() {
        report(ComposerAttachmentError.tooMany)
    }

    /// Puts one error on screen and starts its countdown, replacing anything already there.
    ///
    /// The countdown is restarted rather than left alone, so a second error gets its own
    /// five seconds instead of inheriting what was left of the first one's. That is the
    /// case that shows up in practice: tapping a full composer twice.
    func report(_ error: Error) {
        uploadError = Self.describe(error)
        errorDismissal?.cancel()
        let duration = errorDuration
        errorDismissal = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.uploadError = nil
        }
    }

    /// Takes the error off screen now, and stops the countdown still pointed at it.
    ///
    /// Cancelling matters even though the countdown would only write `nil` over `nil`: the
    /// next error along would otherwise be cleared by *this* error's timer.
    func clearError() {
        errorDismissal?.cancel()
        errorDismissal = nil
        uploadError = nil
    }

    /// Opens the inline camera when the message still has room for a photo.
    func presentCamera() {
        guard !isUploadingForSend else { return }
        guard remainingCapacity > 0 else {
            reportAtCapacity()
            return
        }
        isCameraPresented = true
    }

    func dismissCamera() {
        isCameraPresented = false
    }

    /// Takes a pick and starts preparing it locally.
    ///
    /// Returns immediately: every tile appears at once and fills in as its preview
    /// is prepared, without touching the network.
    func add(_ items: [any ComposerPickedItem]) {
        guard !items.isEmpty, !isUploadingForSend else { return }
        clearError()

        // The cap is enforced here rather than at the picker alone: a paste comes in through
        // this same call, and the picker's own limit cannot see attachments already held.
        let accepted = Array(items.prefix(remainingCapacity))
        if accepted.count < items.count {
            report(ComposerAttachmentError.tooMany)
        }
        guard !accepted.isEmpty else { return }

        let ids = accepted.map { _ in UUID() }
        attachments.append(contentsOf: ids.map {
            ComposerAttachment(id: $0, preview: nil, state: .preparing)
        })

        let batch = Task { [weak self] in
            await self?.prepare(accepted, as: ids)
            return ()
        }
        batches.append(batch)
    }

    /// Drops an attachment — the X on its tile.
    ///
    /// Preparation already in flight for it is left to finish and land nowhere:
    /// ``applyState(_:to:)`` writes only into a row that is still here, so a
    /// removed tile cannot come back when its preparation completes. Cancelling the work
    /// instead would save a few kilobytes of upstream and cost a race worth more
    /// than that.
    func remove(_ id: UUID) {
        guard !isUploadingForSend else { return }
        attachments.removeAll { $0.id == id }
    }

    /// Hands over what a message should carry and empties the composer.
    ///
    /// One call rather than "read, then clear" so there is no window in which a
    /// second send could carry the same pictures twice.
    func takeForSend() -> [BlobDescriptor] {
        let descriptors = readyDescriptors
        guard descriptors.count == attachments.count else { return [] }
        attachments.removeAll()
        clearError()
        return descriptors
    }

    /// Puts attachments back after a send that was refused before it left the
    /// device. The blobs are still on the relay, so the descriptors are still good
    /// — restoring them is what makes an over-ceiling refusal recoverable rather
    /// than a silent loss of the pictures along with the text.
    func restore(_ descriptors: [BlobDescriptor]) {
        guard attachments.isEmpty else { return }
        attachments = descriptors.map {
            ComposerAttachment(id: UUID(), preview: nil, state: .uploaded($0))
        }
    }

    /// Drops everything and stops any pick still being read. Called when the
    /// identity behind the composer goes.
    func reset() {
        for batch in batches { batch.cancel() }
        batches.removeAll()
        attachments.removeAll()
        clearError()
        isCameraPresented = false
    }

    // MARK: - Preparing

    /// Runs a pick's items through the pipeline, at most
    /// ``maxConcurrentUploads`` at a time.
    ///
    /// A bounded group rather than a task each: the first three start, and each
    /// completion starts the next. Two overlapping picks each get their own group,
    /// so the true ceiling is per pick — accepted, because the picker is modal and
    /// two picks can only overlap while one is still finishing.
    private func prepare(_ items: [any ComposerPickedItem], as ids: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(Self.maxConcurrentUploads, items.count) {
                let index = next
                group.addTask { [weak self] in await self?.prepare(items[index], as: ids[index]) }
                next += 1
            }
            while await group.next() != nil {
                guard next < items.count else { continue }
                let index = next
                group.addTask { [weak self] in await self?.prepare(items[index], as: ids[index]) }
                next += 1
            }
        }
    }

    /// One picture: bytes, conversion, and thumbnail, all local.
    ///
    /// Loading is bounded so an iCloud-backed pick cannot hold the composer forever;
    /// conversion is finite local CPU work and deliberately has no deadline.
    private func prepare(_ item: any ComposerPickedItem, as id: UUID) async {
        do {
            let data = try await Self.within(
                sourceDeadline, or: .sourceTimedOut, item.loadData
            )
            let prepared = try await ComposerImagePreparation.prepare(data)
            applyPreview(UIImage(data: prepared.preview), to: id)
            applyState(
                .ready(.init(
                    data: prepared.data,
                    mimeType: prepared.mimeType,
                    filename: item.suggestedFilename
                )),
                to: id
            )
        } catch is CancellationError {
            attachments.removeAll { $0.id == id }
        } catch {
            attachments.removeAll { $0.id == id }
            report(error)
        }
    }

    /// Writes a decoded preview into a row that is still there.
    private func applyPreview(_ preview: UIImage?, to id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].preview = preview
    }

    /// Writes a state transition into a row that is still there.
    ///
    /// The membership check is the whole point: an author who removed a tile while
    /// its preparation was in flight must not see it reappear when that work answers.
    func applyState(_ state: ComposerAttachment.State, to id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    /// One line, in the author's terms, for local preparation or send-time upload.
    static func describe(_ error: Error) -> String {
        switch error {
        case MediaUploadError.rejectedByPolicy:
            "The relay wouldn't store that picture."
        case MediaUploadError.unsupportedType:
            "That kind of file can't be sent yet."
        case ComposerImagePreparation.Failure.notAPicture:
            "That file isn't a picture."
        case ComposerImagePreparation.Failure.couldNotConvert:
            "Couldn't convert that picture for sending."
        case ComposerImagePreparation.Failure.animationCannotBeCleaned:
            // Deliberately says what is true rather than "couldn't send": the only way to
            // strip this one is to decode it, and decoding an animation loses the animation.
            "That animation carries data that can't be removed without flattening it."
        case ComposerAttachmentError.noUploader:
            // Not "sign in": this is reached while the workspace is still opening — on
            // launch, or on a community switch — and an author who is already signed in
            // would be told to do the thing they have just done. Says what is true and
            // what waiting will fix.
            "This conversation isn't ready for pictures yet — try again in a moment."
        case ComposerAttachmentError.sourceTimedOut:
            // Names iCloud because that is what it almost always is, and because it is the
            // one the author can actually do something about.
            "That picture took too long to load — it may still be in iCloud."
        case ComposerAttachmentError.uploadTimedOut:
            "That picture took too long to upload."
        case ComposerAttachmentError.tooMany:
            "You can attach \(selectionLimit) pictures at a time."
        default:
            "Couldn't upload that picture."
        }
    }
}
