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
        guard !text.isEmpty else { return }
        mentionDraft = MentionDraft()
        sendError = nil

        let channel = self.channel
        let sender = self.sender
        let mentionPubkeys = document.mentionedPubkeys(sender: selfPubkey)
        let selfPubkey = self.selfPubkey
        Task { [weak self] in
            do {
                try await sender.enqueue(
                    kind: .channelMessage,
                    content: text,
                    in: channel,
                    tags: OutboundTags.message(
                        channel: channel,
                        mentioning: mentionPubkeys,
                        sender: selfPubkey
                    ),
                    maxContentBytes: OutboxPolicy.maxContentBytes
                )
                // Only once the message is really queued. An over-ceiling send throws
                // here, before anything is enqueued, and a reader up in history must not
                // be yanked to the bottom for a message that never left the device.
                self?.jumpToLatestIfNeeded()
            } catch let error as OutboxError {
                self?.restore(document: document, error: error)
            } catch {
                // A transient send failure leaves the row queued in the outbox for
                // the next drain; nothing to surface and nothing to restore.
            }
        }
    }

    /// Brings an own send into view — but only when it would otherwise land somewhere
    /// its author cannot see it.
    ///
    /// Away from the bottom, or with arrivals held back, the jump is the only thing that
    /// puts what they just wrote on screen. Already at the bottom with nothing held, the
    /// author is looking straight at the place it is about to appear, and re-anchoring
    /// there interrupts a scroll in progress for no gain.
    func jumpToLatestIfNeeded() {
        guard !isAtBottom || heldBackCount > 0 else { return }
        jumpToLatest()
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
    /// scoped ephemeral (S-5); a non-member's typing would be rejected without it.
    func handleTyping(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let instant = clock()
        if let last = lastTypingPublish, instant - last < typingThrottle { return }
        lastTypingPublish = instant

        let channel = self.channel
        let typing = self.typing
        Task { await typing.publishEphemeral(kind: .typing, content: "", tags: [["h", channel]]) }
    }

    private func restore(document: MentionDraft, error: OutboxError) {
        // Preserve whatever the user has since typed, only restoring if untouched.
        if mentionDraft.text.isEmpty { mentionDraft = document }
        sendError = Self.describe(error)
    }

    private static func describe(_ error: OutboxError) -> String {
        switch error {
        case let .contentTooLarge(bytes, limit):
            "Message is too large (\(bytes) bytes; limit \(limit))."
        case .invalidEvent, .notQueued, .encodingFailed:
            "Couldn't send that message."
        }
    }
}
