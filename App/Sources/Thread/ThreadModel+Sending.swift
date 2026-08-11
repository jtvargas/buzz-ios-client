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
    ///
    /// `isAgent` is the "Keep agents mentioned" setting in the only form this model needs it:
    /// `nil` clears the composer exactly as it always has, and a predicate leaves the agents
    /// this reply addressed sitting in it, ready for the next one. It arrives from the view
    /// rather than being read here because both halves of the answer — the setting and
    /// ``EntityNames`` — live in the environment, which a model cannot reach.
    ///
    /// The seed is assigned through ``ThreadModel/mentionDraft`` like anything typed, so the
    /// same `didSet` persists it: leave the thread mid-conversation and the agents are still
    /// addressed on the way back in.
    func sendReply(keepingAgents isAgent: ((String) -> Bool)? = nil) {
        let document = mentionDraft
        let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // The same rules the channel's send states: a picture alone is a reply,
        // preparation must be done.
        guard !attachments.isAttaching else { return }
        guard !text.isEmpty || attachments.hasSendableContent else { return }
        let isChasingOwnSend = shouldJumpToOwnSend
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        guard let media = attachments.takeForSend() else { return }
        guard !text.isEmpty || !media.isEmpty else { return }
        // The author's own key is filtered out for the reason it is filtered out of the tags:
        // a self-mention notifies nobody, and seeding one would park the reader's own name in
        // their composer for the rest of the thread.
        let sender = selfPubkey?.lowercased()
        mentionDraft = isAgent
            .map { predicate in
                document.agentSeed { pubkey in pubkey != sender && predicate(pubkey) }
            }
            ?? MentionDraft()
        sendError = nil
        if isChasingOwnSend { jumpToLatest() }
        Task { [weak self] in
            guard let self else { return }

            do {
                let entry = try await self.sender.enqueueComposerMessage(
                    text: text,
                    in: self.channel,
                    tags: OutboundTags.reply(
                        channel: self.channel,
                        root: self.root,
                        parent: self.root,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ),
                    media: media.map { OutboundMediaPayload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType) }
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
