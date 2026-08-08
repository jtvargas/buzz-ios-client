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
    var focusMessageID: String?
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
