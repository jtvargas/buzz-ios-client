import BuzzKit

/// One pushed conversation: the row its timeline renders, and — when the push came from
/// opening a direct message — the peer the relay said it is with.
///
/// A route type rather than the bare ``BuzzKit/ChannelListRow`` the sidebar pushes,
/// because the two ways into a conversation know different things about it. From the
/// sidebar the roster is already read, so the row is the whole story. From a profile
/// sheet's Message action the channel is seconds old and its roster is still in flight, so
/// the peer travels with the push (see ``OpenedConversation``).
struct ConversationRoute: Hashable {
    let channel: ChannelListRow
    /// The peer this conversation was just opened with, or `nil` when the roster is the
    /// only thing that should name it.
    var knownPeer: String?
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
