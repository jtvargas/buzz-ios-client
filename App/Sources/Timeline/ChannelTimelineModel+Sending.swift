import BuzzKit
import Foundation

// MARK: - Send / retry / typing

/// The channel timeline's outbound side: the composer's send, the failed-row retry, and
/// the throttled own-typing publish.
///
/// Kept beside the model rather than in it so the model file stays about the live
/// observation, pagination, and the rendered tail — the same split reason
/// `ChannelTimelineModel+Rows.swift` exists for.
extension ChannelTimelineModel {
    /// Sends the composer draft. Optimistic and fire-and-forget: the draft is
    /// cleared and the pending row appears through the observation the moment the
    /// outbox row commits, long before the relay's OK. An over-ceiling message
    /// throws before it is queued — the text is restored and surfaced.
    func send() {
        let document = mentionDraft
        let text = document.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A picture with no words is a message. Local preparation must finish first,
        // and a second send cannot overlap the network batch started by the first.
        guard !attachments.isAttaching, !attachments.isUploadingForSend else { return }
        guard !text.isEmpty || attachments.hasSendableContent else { return }
        // Read at the tap, then acted on only after uploads succeed. `enqueue` commits the
        // outbox row and then waits for the drain — a publish round trip for every queued
        // row — so the jump still happens before that await, without moving the reader for
        // an upload that was refused before a message existed.
        //
        // The cost is that a send refused at the door — over the 64 KiB ceiling, the one thing
        // `enqueue` throws for — has already moved the reader. That refusal raises an alert and
        // hands the draft back, so it is neither silent nor lost, and it is not reachable by
        // typing.
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
                    tags: OutboundTags.message(
                        channel: self.channel,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ) + OutboundAttachments.tags(attaching: media),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
                // The message has an id now, so the trip that started at the tap can finish
                // on the message itself rather than on whatever was newest when it began.
                if isChasingOwnSend { self.landOn(ownSend: entry.event.id) }
            } catch let error as OutboxError {
                self.restore(document: document, media: media, error: error)
            } catch {
                self.restore(document: document, media: media, error: error)
            }
        }
    }

    /// Whether an own send has to move the conversation at all.
    ///
    /// Away from the bottom, or with arrivals held back, the jump is the only thing that
    /// puts what they just wrote on screen. Already at the bottom with nothing held, the
    /// author is looking straight at the place it is about to appear, and re-anchoring
    /// there interrupts a scroll in progress for no gain — the content change their own
    /// message makes lands them on it anyway (``ConversationReaderPlace``).
    ///
    /// Read once, at the tap, and carried through the send: by the time the message has an
    /// id this is `true` for a reason that has nothing to do with the author — the jump the
    /// tap asked for has already set ``isAtBottom``.
    var shouldJumpToOwnSend: Bool {
        !isAtBottom || jump.unreadCount > 0
    }

    /// Returns a failed send to the queue and redrains — the "tap to retry" action.
    func retry(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.retry(eventID) }
    }

    /// Publishes an own typing indicator for this channel as the composer changes,
    /// throttled to at most one publish per ``ChannelTimelineModel/typingThrottle``
    /// window. Empty input never publishes — clearing the field is not typing.
    ///
    /// Fire-and-forget: typing is ephemeral (S-3), so a failure is dropped. The
    /// indicator carries the `["h", channel]` tag the relay requires for a channel-
    /// scoped ephemeral (S-5); a non-member's typing would be rejected without it. No
    /// `e` marker: this composer writes at the channel's own level, and a reader in one
    /// of its threads must not be told the channel's traffic is theirs.
    func handleTyping(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let instant = clock()
        if let last = lastTypingPublish, instant - last < typingThrottle { return }
        lastTypingPublish = instant

        let tags = OutboundTags.typing(channel: channel, thread: nil)
        let typing = self.typing
        Task { await typing.publishEphemeral(kind: .typing, content: "", tags: tags) }
    }

    private func restore(document: MentionDraft, media: [BlobDescriptor], error: Error) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if mentionDraft.text.isEmpty { mentionDraft = document }
        // The blobs are still on the relay, so their descriptors are still good:
        // any pre-commit refusal that took the text back must take the pictures too,
        // or the failed send silently loses them.
        attachments.restore(media)
        if let outboxError = error as? OutboxError {
            sendError = Self.describe(outboxError)
        } else {
            sendError = "Couldn't send that message."
        }
    }

    private static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Message is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .notRetryable, .encodingFailed:
            "Couldn't send that message."
        }
    }
}
