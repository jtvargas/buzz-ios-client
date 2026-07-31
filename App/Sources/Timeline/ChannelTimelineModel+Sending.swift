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
        // A picture with no words is a message; an upload still in flight is not
        // ready to be one. The composer disables send in both cases — this is the
        // same rule stated where it is enforced, so a send reaching here another
        // way cannot post a message missing an attachment.
        guard !attachments.isAttaching else { return }
        let media = attachments.takeForSend()
        guard !text.isEmpty || !media.isEmpty else { return }
        mentionDraft = MentionDraft()
        sendError = nil
        // At the tap, and not behind the `await` below. `enqueue` commits the outbox row and
        // then waits for the drain — a publish round trip for every queued row — so a jump
        // issued after it returns lands whenever the relay answers, which on a slow socket is
        // seconds after the author pressed send. The freeze has to come off here for the same
        // reason and one more: the row this whole path is about is newer than the boundary, so
        // while the freeze stands it is not rendered at all and there is nothing to land on.
        //
        // The cost is that a send refused at the door — over the 64 KiB ceiling, the one thing
        // `enqueue` throws for — has already moved the reader. That refusal raises an alert and
        // hands the draft back, so it is neither silent nor lost, and it is not reachable by
        // typing.
        let isChasingOwnSend = shouldJumpToOwnSend
        if isChasingOwnSend { jumpToLatest() }

        let channel = self.channel
        let sender = self.sender
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            do {
                let entry = try await sender.enqueue(
                    kind: .channelMessage,
                    content: OutboundAttachments.content(text, attaching: media),
                    in: channel,
                    tags: OutboundTags.message(
                        channel: channel,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ) + OutboundAttachments.tags(attaching: media),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
                // The message has an id now, so the trip that started at the tap can finish
                // on the message itself rather than on whatever was newest when it began.
                if isChasingOwnSend { self?.landOn(ownSend: entry.event.id) }
            } catch let error as OutboxError {
                self?.restore(document: document, media: media, error: error)
            } catch {
                // A transient send failure leaves the row queued in the outbox for
                // the next drain; nothing to surface and nothing to restore.
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

    private func restore(document: MentionDraft, media: [BlobDescriptor], error: OutboxError) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if mentionDraft.text.isEmpty { mentionDraft = document }
        // The blobs are still on the relay, so their descriptors are still good:
        // a refusal that took the text back must take the pictures back with it,
        // or a send over the ceiling silently loses them.
        attachments.restore(media)
        sendError = Self.describe(error)
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
