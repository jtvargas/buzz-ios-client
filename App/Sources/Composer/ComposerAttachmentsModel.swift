import BuzzKit
import Foundation
import Observation
import UIKit

/// What the composer is carrying besides text.
///
/// Owned by the conversation model beside ``MentionDraft`` and cleared by the same
/// send, so a channel and each of its threads carry their own — picking a photo in
/// a thread cannot put it on the channel's next message.
///
/// # Three rules, all of them the mobile client's
///
/// 1. **Upload on pick.** By send time every attachment is already on the relay.
/// 2. **Send waits for the pick, not for the network.** While anything is still
///    uploading, send is refused — see ``isAttaching``. This is the one place the
///    author is made to wait, and it is the alternative to sending a message that
///    is missing a picture they can see in the composer.
/// 3. **A failed upload leaves nothing behind.** The tile goes and a line of text
///    says why. Keeping a broken tile to retry was considered and dropped: the
///    picture is still in the library, and "pick it again" is a shorter path than
///    a retry affordance nothing else in this composer has.
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
    /// Every attachment in the order it was picked, uploading and uploaded alike.
    private(set) var attachments: [ComposerAttachment] = []

    /// Why the last pick did not become an attachment, for the line under the
    /// strip. Cleared by the next pick.
    var uploadError: String?

    /// At most this many uploads at once. Three, the ceiling the mobile client
    /// uses (`_maxConcurrentImageUploads`), and it bounds memory as much as
    /// bandwidth: converting a 12-megapixel photo holds a bitmap of about 48 MB
    /// while it does it, and ten of those at once is not a thing to do on a phone.
    static let maxConcurrentUploads = 3

    /// The most pictures one visit to the picker may add.
    static let selectionLimit = 10

    /// `nil` before a relay is configured, and in tests that do not exercise
    /// uploading. A pick with no uploader fails with a reason rather than
    /// silently doing nothing.
    private let uploader: (any MediaUploading)?

    /// The in-flight pick batches, so a sign-out or a send can stop them. Not
    /// observable: nothing renders them.
    @ObservationIgnored private var batches: [Task<Void, Never>] = []

    init(uploader: (any MediaUploading)? = nil) {
        self.uploader = uploader
    }

    // MARK: - What the composer asks

    /// Whether anything is still on its way up — the send gate.
    var isAttaching: Bool { attachments.contains(where: \.isUploading) }

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
    /// swaps the strip for a line of red text. What actually moves the bar is those two facts:
    /// whether there is a strip at all, and whether there is an error line under it.
    ///
    /// Computed rather than stored, which costs the conversation a body pass on every
    /// attachment write — a preview decoding, an upload landing — and not only on the ones that
    /// change the bar's height. Accepted for ``ConversationScaffold/contentRevision``' reason:
    /// the events behind it are a picked photo, not a frame. A stored version would need a
    /// `didSet` on both properties feeding it, and a path that forgot one would lose the
    /// declaration silently.
    var barRevision: Int {
        (isEmpty ? 0 : 1) + (uploadError == nil ? 0 : 2)
    }

    /// Whether these attachments alone are enough to justify a send — a picture
    /// with no words is a message.
    var hasSendableContent: Bool { !readyDescriptors.isEmpty }

    // MARK: - Picking

    /// Takes a pick and starts uploading it.
    ///
    /// Returns immediately: every tile appears at once and fills in as its upload
    /// lands, so the strip reflects what was picked before the network has been
    /// touched.
    func add(_ items: [any ComposerPickedItem]) {
        guard !items.isEmpty else { return }
        uploadError = nil

        let ids = items.map { _ in UUID() }
        attachments.append(contentsOf: ids.map {
            ComposerAttachment(id: $0, preview: nil, state: .uploading)
        })

        let batch = Task { [weak self] in
            await self?.upload(items, as: ids)
            return ()
        }
        batches.append(batch)
    }

    /// Drops an attachment — the X on its tile.
    ///
    /// An upload already in flight for it is left to finish and land nowhere:
    /// ``applyState(_:to:)`` writes only into a row that is still here, so a
    /// removed tile cannot come back when its upload completes. Cancelling the request
    /// instead would save a few kilobytes of upstream and cost a race worth more
    /// than that.
    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    /// Hands over what a message should carry and empties the composer.
    ///
    /// One call rather than "read, then clear" so there is no window in which a
    /// second send could carry the same pictures twice.
    func takeForSend() -> [BlobDescriptor] {
        let descriptors = readyDescriptors
        attachments.removeAll()
        uploadError = nil
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
        uploadError = nil
    }

    // MARK: - Uploading

    /// Runs a pick's items through the pipeline, at most
    /// ``maxConcurrentUploads`` at a time.
    ///
    /// A bounded group rather than a task each: the first three start, and each
    /// completion starts the next. Two overlapping picks each get their own group,
    /// so the true ceiling is per pick — accepted, because the picker is modal and
    /// two picks can only overlap while one is still finishing.
    private func upload(_ items: [any ComposerPickedItem], as ids: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(Self.maxConcurrentUploads, items.count) {
                let index = next
                group.addTask { [weak self] in await self?.upload(items[index], as: ids[index]) }
                next += 1
            }
            while await group.next() != nil {
                guard next < items.count else { continue }
                let index = next
                group.addTask { [weak self] in await self?.upload(items[index], as: ids[index]) }
                next += 1
            }
        }
    }

    /// One picture: bytes, conversion, thumbnail, upload.
    private func upload(_ item: any ComposerPickedItem, as id: UUID) async {
        do {
            guard let uploader else { throw ComposerAttachmentError.noUploader }
            let data = try await item.loadData()
            let prepared = try await ComposerImagePreparation.prepare(data)
            // Before the upload rather than after it, so the strip shows the
            // picture while it is going up rather than a placeholder.
            applyPreview(UIImage(data: prepared.preview), to: id)
            let descriptor = try await uploader.upload(
                data: prepared.data,
                mimeType: prepared.mimeType,
                filename: item.suggestedFilename
            )
            applyState(.uploaded(descriptor), to: id)
        } catch is CancellationError {
            attachments.removeAll { $0.id == id }
        } catch {
            attachments.removeAll { $0.id == id }
            uploadError = Self.describe(error)
        }
    }

    /// Writes a decoded preview into a row that is still there.
    private func applyPreview(_ preview: UIImage?, to id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].preview = preview
    }

    /// Writes a landed upload into a row that is still there.
    ///
    /// The membership check is the whole point: an author who removed a tile while
    /// its upload was in flight must not see it reappear when the relay answers.
    private func applyState(_ state: ComposerAttachment.State, to id: UUID) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        attachments[index].state = state
    }

    /// One line, in the author's terms, for something that went wrong between a
    /// pick and an attachment.
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
        case ComposerAttachmentError.noUploader:
            "Not connected to a relay yet."
        default:
            "Couldn't upload that picture."
        }
    }
}
