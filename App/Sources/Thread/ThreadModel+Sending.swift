import BuzzKit
import Foundation

// MARK: - Reply

/// The thread's outbound side: the reply composer's send.
///
/// Beside the model rather than in it, for the reason `ChannelTimelineModel+Sending.swift`
/// exists — the model file stays about the live observation and the rendered thread,
/// and the two conversations' send paths sit next to each other where their rules can
/// be compared. The failure half is in `ThreadModel+SendFailure.swift`.
extension ThreadModel {
    /// Sends the reply draft, threaded to the root. Optimistic and fire-and-forget:
    /// the pending reply appears through the observation the moment the outbox row
    /// commits. An over-ceiling reply throws before it is queued — the text is
    /// restored and surfaced.
    func sendReply() {
        let document = mentionDraft
        let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same two rules the channel's send states: a picture alone is a reply,
        // and an upload still in flight is not ready to be one.
        guard !attachments.isAttaching else { return }
        let media = attachments.takeForSend()
        guard !text.isEmpty || !media.isEmpty else { return }
        mentionDraft = MentionDraft()
        sendError = nil

        let channel = self.channel
        let root = self.root
        let sender = self.sender
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            do {
                try await sender.enqueue(
                    kind: .channelMessage,
                    content: OutboundAttachments.content(text, attaching: media),
                    in: channel,
                    tags: OutboundTags.reply(
                        channel: channel,
                        root: root,
                        parent: root,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ) + OutboundAttachments.tags(attaching: media),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
                // Only once the reply is really queued: an over-ceiling reply throws
                // before anything is enqueued, and a reader up the thread must not be
                // yanked to the bottom for a reply that never left the device.
                self?.jumpToLatestIfNeeded()
            } catch let error as OutboxError {
                self?.restore(document: document, media: media, error: error)
            } catch {
                // A transient send failure leaves the reply queued for the next drain.
            }
        }
    }

}
