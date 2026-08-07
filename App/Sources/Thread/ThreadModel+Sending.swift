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
        // The same rules the channel's send states: a picture alone is a reply,
        // preparation must be done, and send-time uploads cannot overlap.
        guard !attachments.isAttaching, !attachments.isUploadingForSend else { return }
        guard !text.isEmpty || attachments.hasSendableContent else { return }
        let isChasingOwnSend = shouldJumpToOwnSend
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            guard await self?.attachments.prepareForSend() == true else { return }
            guard let self else { return }
            let media = self.attachments.takeForSend()
            guard !text.isEmpty || !media.isEmpty else { return }
            self.mentionDraft = MentionDraft()
            self.sendError = nil
            if isChasingOwnSend { self.jumpToLatest() }

            do {
                let entry = try await self.sender.enqueue(
                    kind: .channelMessage,
                    content: OutboundAttachments.content(text, attaching: media),
                    in: self.channel,
                    tags: OutboundTags.reply(
                        channel: self.channel,
                        root: self.root,
                        parent: self.root,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ) + OutboundAttachments.tags(attaching: media),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
                // The reply has an id now, so the trip that started at the tap can finish on
                // the reply itself rather than on whatever was newest when it began.
                if isChasingOwnSend { self.landOn(ownSend: entry.event.id) }
            } catch let error as OutboxError {
                self.restore(document: document, media: media, error: error)
            } catch {
                self.restore(document: document, media: media, error: error)
            }
        }
    }

}
