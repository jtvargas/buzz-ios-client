import BuzzKit
import NostrCore

/// Editing and deleting a *published* message, shared by the channel and a thread.
///
/// The two surfaces had identical bodies for all three of these, which is exactly the
/// duplication that lets a channel and a thread drift into disagreeing about who may
/// delete what. One implementation, called from both conformances.
///
/// Free functions rather than a protocol extension because what they need — a store, a
/// sender, a channel id, the reader's key — the two models hold under different access
/// levels; passing them in keeps this testable without either model.
enum MessageMutation {
    /// What `identity` may do to `row`, or ``BuzzKit/MessageAuthority/none`` when the
    /// question does not arise.
    ///
    /// A relay notice and a row that has not landed both answer `none`: neither is a
    /// published message, so neither has anything for a `9005` or a `40003` to name.
    static func authority(
        store: BuzzEventStore,
        identity: String?,
        channel: String,
        row: TimelineRow
    ) -> MessageAuthority {
        guard let identity, !row.isNotice, row.delivery == .sent else { return .none }
        return (try? store.messageAuthority(
            identity: identity,
            channel: channel,
            message: row.id,
            author: row.pubkey
        )) ?? .none
    }

    /// Deletes a published message for everybody — a `kind:9005` naming it.
    ///
    /// Through the outbox like any other send, so it survives a relaunch and retries on its
    /// own. The message stays on screen until the relay accepts: the deletion applies when
    /// the event lands in the log, and one the relay refuses should not have hidden
    /// anything in the meantime. A message that came *back* would read worse than one that
    /// took a moment to go.
    static func remove(
        _ eventID: String,
        in channel: String,
        via sender: any MessageSending
    ) async {
        try? await sender.enqueue(
            kind: .groupDeleteEvent,
            content: "",
            in: channel,
            tags: OutboundTags.deletion(channel: channel, target: eventID),
            maxContentBytes: OutboxPolicy.maxContentBytes
        )
    }

    /// Rewrites a published message — a `kind:40003` carrying the new text.
    static func edit(
        _ eventID: String,
        to text: String,
        in channel: String,
        via sender: any MessageSending
    ) async {
        try? await sender.enqueue(
            kind: .messageEdit,
            content: text,
            in: channel,
            tags: OutboundTags.edit(channel: channel, target: eventID),
            maxContentBytes: OutboxPolicy.maxContentBytes
        )
    }
}
