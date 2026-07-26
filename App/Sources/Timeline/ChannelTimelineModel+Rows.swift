import BuzzKit
import Foundation

// MARK: - Reactions & row actions

/// The per-row reads and actions a timeline row needs, kept beside the model rather
/// than in it so the model file stays about scroll position, pagination, and sending.
///
/// Everything a row asks for here is an O(1) dictionary read against state the
/// observation already produced — the spec's §9 rule that a render pass never
/// re-resolves anything.
extension ChannelTimelineModel {
    /// The reaction groups to render under a row, empty when it has none.
    func reactions(for id: String) -> [ReactionGroup] { reactionGroups[id] ?? [] }

    /// Whether a row is the local identity's own send — the gate on the delete
    /// affordance for a pending or failed row.
    func isOwn(_ row: TimelineRow) -> Bool {
        guard let selfPubkey else { return false }
        return row.pubkey == selfPubkey
    }

    /// Reads reactions for `ids` off the main actor. `store` and `selfPubkey` are
    /// immutable, so this is safe to call from the `nonisolated` observation loop.
    nonisolated func fetchReactions(for ids: [String]) -> [String: [ReactionGroup]] {
        (try? store.reactions(for: ids, selfPubkey: selfPubkey)) ?? [:]
    }

    /// The users a row mentions, empty when it mentions none — handed to the row's
    /// resolver so `@`-tokens resolve from the message's own data.
    func mentions(for id: String) -> [MentionRef] {
        mentionRefs[id].map { Array($0) } ?? []
    }

    /// Reads mentions for `ids` off the main actor. `store` is immutable, so this is
    /// safe to call from the `nonisolated` observation loop.
    nonisolated func fetchMentions(for ids: [String]) -> [String: MentionRefList] {
        (try? store.mentions(for: ids)) ?? [:]
    }

    /// Sends a reaction on a message through the durable send path — an ordinary
    /// persisted kind-7, not an ephemeral.
    func react(_ emoji: String, on targetID: String) {
        let channel = self.channel
        let sender = self.sender
        Task {
            try? await sender.enqueue(
                kind: .reaction,
                content: emoji,
                in: channel,
                tags: OutboundTags.reaction(target: targetID),
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        }
    }

    /// Toggles a chip: withdraws the local identity's own reaction (a kind-5 naming
    /// it) when it is highlighted, otherwise adds that emoji.
    func toggleReaction(_ group: ReactionGroup, on targetID: String) {
        guard group.reactedBySelf, let reactionID = group.selfReactionID else {
            react(group.emoji, on: targetID)
            return
        }
        let channel = self.channel
        let sender = self.sender
        Task {
            try? await sender.enqueue(
                kind: .deletion,
                content: "",
                in: channel,
                tags: OutboundTags.withdrawal(reactionID: reactionID),
                maxContentBytes: OutboxPolicy.maxContentBytes
            )
        }
    }

    /// Drops an own pending or failed row — the context-menu "delete".
    func delete(_ eventID: String) {
        let sender = self.sender
        Task { try? await sender.discard(eventID) }
    }
}
