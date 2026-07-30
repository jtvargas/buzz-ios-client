import Foundation

/// How one conversation presents itself: a channel, a DM with a person, a DM with an
/// agent, or a DM with several people — resolved once by ``EntityNames`` and reused by
/// the sidebar, the conversation header, the thread header, and the Drafts screen, so
/// they all agree.
///
/// Split out of ``EntityNames`` rather than living beside it: the resolver is a function
/// of a directory snapshot, and this is the shape of its answer. Four surfaces read the
/// answer and one builds it.
struct ConversationIdentity: Hashable, Sendable, Identifiable {
    enum Kind: Hashable, Sendable {
        case channel
        case direct
        case agent
        /// A direct message with more than one other person — Slack's group DM. Titled by
        /// who is in it and filed with the direct messages, but it has no single peer, so
        /// everything a face, a presence dot, or a profile stands for is absent here.
        case group
    }

    /// The underlying channel's group id. Never rendered — carried so a view can act
    /// on the conversation it names.
    let channelID: String
    let kind: Kind
    /// The name to show: the channel's name, or the peer's for a direct message.
    let title: String
    /// The other person in a direct message; `nil` for a channel.
    let peer: String?
    let picture: URL?
    let initials: String
    let isPrivate: Bool
    /// How many people the directory currently knows are in this conversation, which is
    /// what a group direct message draws in place of a face. Zero while the roster is
    /// still arriving — a count, not a claim that nobody is here.
    var memberCount: Int = 0

    var id: String { channelID }

    /// Whether this is a direct message rather than a channel — with one person, with an
    /// agent, or with several people.
    var isDirect: Bool { kind != .channel }

    /// Whether this is a conversation with exactly one other party, which is the question
    /// every surface that wants to show *them* is really asking: their face, their
    /// presence, their profile. A group direct message answers `false` — it is a direct
    /// message with nobody in particular on the other end.
    var isOneToOne: Bool { peer != nil }

    /// The seed for a monogram's colour — the peer for a DM so a person keeps one
    /// tint everywhere, the channel otherwise.
    var avatarSeed: String { peer ?? channelID }
}
