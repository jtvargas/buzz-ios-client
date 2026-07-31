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
        // At the tap, for the reason ``ChannelTimelineModel/send()`` states at length: the
        // enqueue waits on a publish round trip, and the freeze has to come off before the
        // reply this is about can be rendered at all.
        let isChasingOwnSend = shouldJumpToOwnSend
        if isChasingOwnSend { jumpToLatest() }

        let channel = self.channel
        let root = self.root
        let sender = self.sender
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            do {
                let entry = try await sender.enqueue(
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
                // The reply has an id now, so the trip that started at the tap can finish on
                // the reply itself rather than on whatever was newest when it began.
                if isChasingOwnSend { self?.landOn(ownSend: entry.event.id) }
            } catch let error as OutboxError {
                self?.restore(document: document, media: media, error: error)
            } catch {
                // A transient send failure leaves the reply queued for the next drain.
            }
        }
    }

}
