import BuzzKit

/// One pushed conversation: the row its timeline renders, and — when the push came from
/// opening a direct message — the people the relay said it is with.
///
/// A route type rather than the bare ``BuzzKit/ChannelListRow`` the sidebar pushes,
/// because the two ways into a conversation know different things about it. From the
/// sidebar the roster is already read, so the row is the whole story. From a profile
/// sheet's Message action, or from the new-direct-message sheet, the channel is seconds old
/// and its roster is still in flight, so the people travel with the push (see
/// ``OpenedConversation``).
struct ConversationRoute: Hashable {
    let channel: ChannelListRow
    /// The people this conversation was just opened with, or empty when the roster is the
    /// only thing that should name it. One of them is a one-to-one; more is a group.
    var knownPeers: [String] = []
    /// Whether the composer takes the keyboard once the conversation has settled. Set only
    /// by the Drafts screen, which is a request to finish writing something — the same
    /// meaning ``ThreadRoute/focusesComposer`` carries.
    ///
    /// Deliberately part of `Hashable`, unlike ``ThreadRoute``'s: the identity that stops
    /// a conversation stacking on itself is ``pushed(onto:)``'s explicit `channel.id`
    /// comparison, not this type's equality, so folding it in costs nothing and keeps two
    /// routes to the same channel distinguishable in a path.
    var focusesComposer = false
    /// One message this conversation is being opened *at*, set only by an arrival that names
    /// one — search today. The conversation still opens at its newest message and this is
    /// walked back to behind the reader; see ``ChannelTimelineModel/focus(on:)``.
    ///
    /// Part of `Hashable` for ``focusesComposer``'s reason, and it matters slightly more
    /// here: two searches landing on two different messages in one channel are two different
    /// arrivals, and only this tells them apart.
    var focus: ConversationFocus?
}

/// One message a conversation is being opened *at*, and when it was sent.
///
/// # Why the timestamp travels with the id
///
/// The walk that fetches history back to the message needs to know when to stop, and an id
/// on its own cannot say. Without the timestamp the only terminator is "history ran out",
/// which is both far too slow — a message that is *not* on this surface costs a walk to the
/// beginning of the channel to prove it — and unreachable in practice, because a walk that
/// long meets a relay hiccup or a page budget first and reports a guess.
///
/// With it the answer is exact and local: once the oldest loaded row is older than this
/// message's own place in the `(created_at, id)` order, every row at or after that place is
/// loaded, so the message is not on this surface and no further reading can change that.
/// Every caller already holds it — a search hit carries `created_at` whether it came from
/// the index or from the relay.
struct ConversationFocus: Hashable {
    let messageID: String
    /// The message's own `created_at`, the second half of its key in the timeline's
    /// `(created_at, id)` total order.
    let sentAt: Int64
}

extension ConversationRoute {
    /// `path` with this conversation opened: exactly one instance of it, on top.
    ///
    /// Pure so the rule is tested rather than driven through a navigation stack.
    ///
    /// A plain append is wrong here because the tap that opens a conversation is reachable
    /// from *inside* that same conversation: the peer's face is on every row of a DM, and
    /// their profile sheet offers Message. Appending there pushed a second copy of the
    /// conversation onto the first, so backing out of a DM went through an identical DM.
    /// Already-on-top is left completely alone rather than replaced, because re-assigning
    /// the same conversation as a *different* element value is a pop-and-push the reader
    /// would watch happen.
    func pushed(onto path: [ConversationRoute]) -> [ConversationRoute] {
        guard path.last?.channel.id != channel.id else { return path }
        var updated = path.filter { $0.channel.id != channel.id }
        updated.append(self)
        return updated
    }
}
