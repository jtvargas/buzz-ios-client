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
        // A picture with no words is a message. Local preparation must finish first.
        guard !attachments.isAttaching else { return }
        guard !text.isEmpty || attachments.hasSendableContent else { return }
        // Read at the tap, then stage and enqueue as one durable operation. The pending row
        // appears before its background upload finishes, so the jump happens immediately
        // and the composer is free for the next message.
        //
        // A send refused before the outbox transaction commits has already moved the reader.
        // That refusal raises an alert and hands the draft and local bytes back, so it is
        // neither silent nor lost.
        let isChasingOwnSend = shouldJumpToOwnSend
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        guard let media = attachments.takeForSend() else { return }
        guard !text.isEmpty || !media.isEmpty else { return }
        mentionDraft = MentionDraft()
        sendError = nil
        if isChasingOwnSend { jumpToLatest() }
        Task { [weak self] in
            guard let self else { return }

            do {
                let entry = try await self.sender.enqueueComposerMessage(
                    text: text,
                    in: self.channel,
                    tags: OutboundTags.message(
                        channel: self.channel,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ),
                    media: media.map { OutboundMediaPayload(data: $0.data, filename: $0.filename, mimeType: $0.mimeType) }
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

    private func restore(
        document: MentionDraft,
        media: [ComposerAttachment.LocalPayload],
        error: Error
    ) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if mentionDraft.text.isEmpty { mentionDraft = document }
        // No outbox row committed, so the local bytes return to the composer.
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
        case .mediaUnavailable:
            "Media upload isn't available right now."
        case .mediaStagingFailed:
            "Couldn't save those pictures for sending. Check device storage and try again."
        }
    }
}
