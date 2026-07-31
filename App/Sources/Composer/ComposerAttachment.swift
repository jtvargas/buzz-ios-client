import BuzzKit
import Foundation
import UIKit

/// One picture the composer is holding, from the moment it is picked to the moment
/// the message carrying it goes.
///
/// # Uploaded before it is sent
///
/// The upload happens at *pick* time. By the time an author presses send, every
/// attachment here already exists on the relay and all the message has to carry is
/// its ``BuzzKit/BlobDescriptor`` — so send is instant, a failure surfaces while
/// the author is still looking at the composer, and a message can never half-go
/// with a picture missing from it. That is the mobile client's model
/// (`buzz/mobile/lib/features/channels/compose_bar.dart`), copied deliberately.
///
/// # The preview is local
///
/// ``preview`` is decoded from the bytes on this device, not fetched back from the
/// URL the relay returns — which is what the mobile client draws. Same picture,
/// one fewer round trip, and it can be shown *during* the upload rather than
/// after it, so the strip shows the photo that was picked instead of an anonymous
/// spinner.
@MainActor
struct ComposerAttachment: Identifiable {
    enum State: Equatable {
        /// On its way to the relay.
        case uploading
        /// Stored, and ready to be named by a message.
        case uploaded(BlobDescriptor)
    }

    /// Identity is assigned here rather than taken from the picture, because a
    /// picture has no identity until the relay has hashed it — and the tile is on
    /// screen before that. Attaching the same photo twice makes two attachments,
    /// which is what an author who picked it twice asked for.
    let id: UUID
    /// The picture itself, once it has been decoded. `nil` for the moment between
    /// the pick landing and the decode finishing.
    var preview: UIImage?
    var state: State

    var descriptor: BlobDescriptor? {
        guard case let .uploaded(descriptor) = state else { return nil }
        return descriptor
    }

    var isUploading: Bool { state == .uploading }
}

/// Something a picker handed over, as the composer needs it.
///
/// The seam that keeps `PhotosUI` at the edge of the app: ``ComposerAttachmentsModel``
/// never sees a `PhotosPickerItem`, so its behaviour — the cap on concurrent
/// uploads, a removal racing an upload, a refusal — is testable without a photo
/// library. It is also where the next source plugs in: a camera capture and a file
/// import are conformances, not a second pipeline.
protocol ComposerPickedItem: Sendable {
    /// What the source calls this, when it has a name worth carrying. Pictures do
    /// not — they are rendered, not named — so this is `nil` for a photo pick and
    /// is here for the file attachment that comes later.
    var suggestedFilename: String? { get }
    /// The bytes, however the source produces them.
    func loadData() async throws -> Data
}

/// What can go wrong on the way from a pick to an attachment.
enum ComposerAttachmentError: Error, Equatable {
    /// The picker returned an item that yielded no bytes.
    case emptyPick
    /// There is nowhere to upload to — no relay is configured yet.
    case noUploader
    /// The bytes never arrived from the source.
    ///
    /// Overwhelmingly this is iCloud: a photo kept in the cloud under *Optimise
    /// iPhone Storage* has to be fetched before `loadTransferable` can answer, and
    /// on a weak connection that fetch has no natural end. Without this the tile
    /// simply span for ever — the owner's report.
    case sourceTimedOut
    /// The relay accepted the connection and then stopped answering.
    case uploadTimedOut
    /// More pictures were offered than one message may carry.
    case tooMany
}
