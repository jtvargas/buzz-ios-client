import BuzzKit
import Foundation

/// What the banner above the strip says when a pick or a staging attempt fails.
///
/// Split out of ``ComposerAttachmentsModel`` because it is a vocabulary rather than
/// behaviour: every line here is a sentence shown to an author, and the model beside
/// it is about bounding, concurrency and removal races. Keeping them apart also keeps
/// each readable — the switch grew a branch per failure the composer learned to have.
///
/// Two switches rather than one, split by *where the failure came from*: the relay's
/// refusals are one vocabulary and this device's own are another, and a reader looking
/// for "what does the relay say when it will not take this" should not have to read
/// past iCloud timeouts to find it.
extension ComposerAttachmentsModel {
    /// One line, in the author's terms, for local preparation failures.
    static func describe(_ error: Error) -> String {
        relayDescription(error) ?? localDescription(error)
    }

    /// The refusals that came back from — or were predicted for — the relay.
    private static func relayDescription(_ error: Error) -> String? {
        switch error {
        case MediaUploadError.rejectedByPolicy:
            "The relay wouldn't store that picture."
        case MediaUploadError.unsupportedType:
            // Names the kinds rather than only refusing: what the relay blocks is web
            // pages and programs, and an author who picked one is otherwise left
            // guessing which part of their file was the problem.
            "Web pages and programs can't be attached."
        case let MediaUploadError.tooLarge(_, max):
            "Files can be up to \(max / 1024 / 1024) MB."
        default:
            nil
        }
    }

    /// The failures that happen on this device, before anything is sent.
    private static func localDescription(_ error: Error) -> String {
        switch error {
        case ComposerImagePreparation.Failure.notAPicture:
            // Reached from the photo library only: a file import routes bytes that are
            // not a picture to the document path instead of failing here.
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
        case ComposerAttachmentError.emptyPick:
            "That file is empty."
        case ComposerAttachmentError.tooMany:
            // "items", not "pictures": the same five now hold files too, and an author
            // stopped at five while attaching documents should not be told about photos.
            "You can attach \(selectionLimit) items at a time."
        default:
            "Couldn't attach that."
        }
    }
}
