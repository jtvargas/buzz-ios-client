import BuzzKit
import Foundation

// MARK: - When a reply does not go out

/// What the author gets back when the outbox refuses a reply: their text, and a sentence
/// naming the reason.
///
/// Beside the model rather than in it, because the wording is the only thing here a person
/// reads — keeping it apart is what stops an error string being edited in the same breath
/// as the send path that raised it.
extension ThreadModel {
    /// Puts the draft back and surfaces the reason.
    ///
    /// The draft is only restored into an *empty* composer: an author who has already
    /// started typing again owns what is in front of them, and overwriting it to hand back
    /// a copy of what they sent is the worse of the two losses.
    /// - Parameter media: the local attachment bytes the refused reply was carrying.
    func restore(
        document: MentionDraft,
        media: [ComposerAttachment.LocalPayload],
        error: Error
    ) {
        if mentionDraft.text.isEmpty { mentionDraft = document }
        attachments.restore(media)
        if let outboxError = error as? OutboxError {
            sendError = Self.describe(outboxError)
        } else {
            sendError = "Couldn't send that reply."
        }
    }

    static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Reply is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .notRetryable, .encodingFailed:
            "Couldn't send that reply."
        case .mediaUnavailable:
            "Media upload isn't available right now."
        case .mediaStagingFailed:
            "Couldn't save those pictures for sending. Check device storage and try again."
        }
    }
}
