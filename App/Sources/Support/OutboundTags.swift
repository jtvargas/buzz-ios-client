import NostrCore

/// Builds the tag sets for the events the timeline and thread composers send.
///
/// The shapes match how this channel's real events mark themselves — verified
/// against the store fixtures and the upstream Buzz clients (desktop/mobile
/// `send_message_provider` for replies, `channel_management_provider` /
/// `build_reaction` for reactions), so a message Hive sends threads and reacts the
/// same way the rest of the workspace reads. Kept pure and view-free so the marker
/// logic is unit-testable on its own, round-tripped through
/// ``NostrCore/NostrEvent/threadReference``.
enum OutboundTags {
    /// A channel message's scope plus normalized mention identities.
    static func message(
        channel: String,
        mentioning pubkeys: [String],
        sender: String?
    ) -> [[String]] {
        addingMentions(pubkeys, sender: sender, to: [["h", channel]])
    }

    /// NIP-10 marked `e` tags for a thread reply, plus the channel `h` scope.
    ///
    /// - A direct reply to the thread head (`parent == root`) carries a single
    ///   `["e", root, "", "reply"]`.
    /// - A nested reply carries `["e", root, "", "root"]` then
    ///   `["e", parent, "", "reply"]`.
    ///
    /// The resolver (and the projector that reads it) take the last `reply` marker
    /// as the parent and the `root` marker as the root, so these two shapes place a
    /// reply in its thread identically to every other client.
    static func reply(
        channel: String,
        root: String,
        parent: String,
        mentioning pubkeys: [String] = [],
        sender: String? = nil
    ) -> [[String]] {
        var tags: [[String]] = [["h", channel]]
        if parent == root {
            tags.append(["e", root, "", "reply"])
        } else {
            tags.append(["e", root, "", "root"])
            tags.append(["e", parent, "", "reply"])
        }
        return addingMentions(pubkeys, sender: sender, to: tags)
    }

    /// A typing indicator's tags: the channel `h` scope, and — inside a thread — the
    /// same NIP-10 markers the reply it precedes will carry.
    ///
    /// Deliberately built from ``reply(channel:root:parent:mentioning:sender:)`` rather
    /// than written out again: an indicator that scoped differently from the message it
    /// announces would raise the strip in one place and land the reply in another. The
    /// agent harness builds its own the same way (`buzz-acp`'s `build_typing_event`).
    static func typing(channel: String, thread root: String?) -> [[String]] {
        guard let root else { return [["h", channel]] }
        return reply(channel: channel, root: root, parent: root)
    }

    /// A NIP-25 reaction's tags: a single `e` referencing the target message. The
    /// projector reads the last `e` as the target and the event content as the
    /// emoji, matching `build_reaction`. Bare `["e", target]`, no `h` or `p` — the
    /// upstream shape.
    static func reaction(target: String) -> [[String]] {
        [["e", target]]
    }

    /// A reaction withdrawal's tags: a kind-5 deletion naming the reaction event.
    /// The projector records it as a deletion of that reaction; the read-time
    /// authority (its own author) makes it take effect.
    static func withdrawal(reactionID: String) -> [[String]] {
        [["e", reactionID]]
    }

    /// A message deletion's tags: the channel `h` scope and a single `e` naming the
    /// message to remove.
    ///
    /// The `h` is not optional the way a reaction's is. The relay resolves the target and
    /// **rejects the deletion outright** unless the target belongs to the `h`-tagged
    /// channel (`side_effects.rs`, the `9005` arm) — the check that stops a deletion in one
    /// room from reaching into another.
    static func deletion(channel: String, target: String) -> [[String]] {
        [["h", channel], ["e", target]]
    }

    /// An edit's tags: the channel `h` scope and a single `e` naming the message being
    /// rewritten. The new text is the event's *content*.
    ///
    /// Same channel check as a deletion, and the projector takes the **last** `e` as the
    /// target, so exactly one is sent.
    static func edit(channel: String, target: String) -> [[String]] {
        [["h", channel], ["e", target]]
    }

    private static func addingMentions(
        _ pubkeys: [String],
        sender: String?,
        to base: [[String]]
    ) -> [[String]] {
        let sender = sender?.lowercased()
        var seen = Set<String>()
        var tags = base
        for pubkey in pubkeys {
            let normalized = pubkey.lowercased()
            guard normalized != sender, seen.insert(normalized).inserted else { continue }
            tags.append(["p", normalized])
            if seen.count == 50 { break }
        }
        return tags
    }
}
