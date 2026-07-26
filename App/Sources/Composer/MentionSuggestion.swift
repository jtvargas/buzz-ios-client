import BuzzKit
import Foundation

/// What a composer token refers to, and the character that opens it.
///
/// One enum rather than two code paths: detection, ranking, insertion, tinting, and
/// atomic deletion all branch on this single value, so a channel reference cannot
/// drift away from a person reference in any of them.
enum MentionKind: Character, Hashable, Sendable, CaseIterable {
    /// A person — a member or an eligible agent. The only kind that tags.
    case user = "@"
    /// A channel reference. Text plus a tint; it never contributes a `p` tag.
    case channel = "#"

    /// The character that opens this kind of token.
    var trigger: Character { rawValue }
}

/// One row the suggestion panel can show, and everything the insertion path needs
/// to know about it.
///
/// The panel, the ranking index, and ``MentionDraft/insert(_:replacing:)`` are all
/// written against this type, which is what keeps `#channel` completion from being a
/// parallel implementation of `@user` completion: adding the case added a payload,
/// not a second pipeline.
enum MentionSuggestion: Identifiable, Hashable, Sendable {
    case user(MentionCandidateProfile)
    case channel(ChannelSuggestion)

    var kind: MentionKind {
        switch self {
        case .user: .user
        case .channel: .channel
        }
    }

    /// The human-readable name, without the trigger. Never a hex key and never a
    /// channel group id — for a person this is the candidate's own resolved
    /// `displayName`, which already falls back through profile → agent directory →
    /// key prefix inside BuzzKit.
    var label: String {
        switch self {
        case let .user(candidate): candidate.displayName
        case let .channel(channel): channel.name
        }
    }

    /// The identity kept in the draft's token list, out of the text: a lowercased
    /// hex pubkey for a person, a channel group id for a channel.
    var entityID: String {
        switch self {
        case let .user(candidate): candidate.pubkey.lowercased()
        case let .channel(channel): channel.id
        }
    }

    /// What is typed into the draft — the trigger plus the label, and nothing else.
    /// The single space that follows is the insertion's business, not the label's.
    var insertionLabel: String { "\(kind.trigger)\(label)" }

    /// The quiet second line in the panel: what kind of thing this is.
    var secondaryLabel: String {
        switch self {
        case let .user(candidate):
            if candidate.isAgent { return "Agent" }
            return candidate.secondaryLabel ?? "Member"
        case let .channel(channel):
            return channel.isPrivate ? "Private channel" : "Channel"
        }
    }

    /// The avatar artwork for a person, when the profile carries one. Channels draw a
    /// glyph instead, so they have none by design.
    var pictureURL: URL? {
        guard case let .user(candidate) = self else { return nil }
        return candidate.picture.flatMap(URL.init(string:))
    }

    /// Whether the panel marks this row as an agent.
    var isAgent: Bool {
        guard case let .user(candidate) = self else { return false }
        return candidate.isAgent
    }

    /// Whether the panel marks this row as a closed channel.
    var isPrivateChannel: Bool {
        guard case let .channel(channel) = self else { return false }
        return channel.isPrivate
    }

    /// Stable across a refresh of the index, and distinct across kinds — a channel
    /// whose group id happened to equal a pubkey would still be its own row.
    var id: String { "\(kind.trigger)\(entityID)" }

    /// Where this row sorts before scoring: channel members first, then other
    /// people, then agents — the Phase-4 order, preserved exactly. Every channel
    /// shares one group, so channel results fall through to score and then to the
    /// read's own alphabetical order.
    var rankingGroup: Int {
        switch self {
        case let .user(candidate):
            if candidate.isChannelMember { return 0 }
            return candidate.isAgent ? 2 : 1
        case .channel:
            return 0
        }
    }

    /// The secondary string matching also scans at name priority — a person's NIP-05.
    /// Deliberately empty for a channel: its only other handle is the group id, and
    /// letting an opaque id score as highly as a name would let it outrank one.
    var matchSecondary: String {
        switch self {
        case let .user(candidate): candidate.secondaryLabel ?? ""
        case .channel: ""
        }
    }

    /// The identifier the last-resort prefix match scans: a pubkey or a group id.
    var matchIdentifier: String { entityID }
}
