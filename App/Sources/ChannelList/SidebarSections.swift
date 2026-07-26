import BuzzKit
import Foundation

/// The sidebar's three groupings (§8): Channels, Direct Messages, Agents.
///
/// A section is *derived*, never stored: which one a conversation lands in is a
/// projection of ``ConversationIdentity/Kind``, which the foundation already decided
/// from the roster. There is no second classifier here.
enum SidebarSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case channels
    case directMessages
    case agents

    var id: String { rawValue }

    /// The header's label.
    var title: String {
        switch self {
        case .channels: "Channels"
        case .directMessages: "Direct Messages"
        case .agents: "Agents"
        }
    }

    /// The `UserDefaults` key behind this section's expansion state.
    ///
    /// The exact strings are pinned by a test: renaming one silently discards the
    /// expansion every existing install has chosen, and nothing else would catch it.
    var expansionStorageKey: String { "sidebar.section.\(rawValue).expanded" }

    /// Sections start open. A sidebar that opens collapsed hides the conversations the
    /// app exists to show; the persisted flag only ever records a deliberate choice to
    /// close one.
    static let defaultIsExpanded = true

    /// Which section a resolved conversation belongs in.
    ///
    /// The product rules — "a DM is a channel whose roster is exactly two members
    /// including me", "an agent DM is one whose peer is an agent" — live once, in
    /// ``EntityNames/conversation(for:)``. This function only maps the answer onto a
    /// heading.
    static func section(for kind: ConversationIdentity.Kind) -> SidebarSection {
        switch kind {
        case .channel: .channels
        case .direct: .directMessages
        case .agent: .agents
        }
    }
}

/// How one row advertises unread activity.
///
/// Two *visually distinct* states, the pattern worth lifting from the Buzz Flutter
/// client: a quiet dot for "there is something new in here", a numeric pill for
/// "something new in here is addressed to you". Folding both into one badge is
/// exactly what makes a mention easy to walk past.
enum UnreadIndicator: Hashable, Sendable {
    /// Caught up — nothing drawn.
    ///
    /// Deliberately not spelled `none`: an enum case by that name is shadowed by
    /// `Optional.none` at every comparison site, so `dictionary[key] == .none` silently
    /// asks whether the *lookup* failed instead of whether the row is read.
    case caughtUp
    /// Unread messages, none of which mention the local identity: a small dot.
    case unread
    /// Unread messages that mention the local identity: a numeric pill.
    case mention(Int)

    /// The indicator for a channel's unread count and whether those unread messages
    /// mention you.
    ///
    /// # Known limitation
    ///
    /// `mentionsSelf` can only be answered from the **newest** message's `p` tags:
    /// ``ChannelListRow`` carries one message's worth of preview and
    /// ``BuzzEventStore/mentions(for:)`` is asked about exactly those ids, so there is
    /// no per-channel "unread mentions" count to read. A mention sitting in an older
    /// but still-unread message therefore shows as a plain dot. That is the honest
    /// reading of the data the model has, not an approximation of a count it does not.
    static func resolve(unreadCount: Int, mentionsSelf: Bool) -> UnreadIndicator {
        guard unreadCount > 0 else { return .caughtUp }
        return mentionsSelf ? .mention(unreadCount) : .unread
    }

    /// Whether the row should read as unread (bolder title, primary-coloured preview).
    var isUnread: Bool { self != .caughtUp }

    /// The pill's text, capped so a very busy channel never widens the row. `nil` for
    /// the states that draw no pill.
    var badgeText: String? {
        guard case let .mention(count) = self else { return nil }
        return count > 99 ? "99+" : "\(count)"
    }

    /// The spoken form, folded into the row's combined label so VoiceOver does not
    /// meet an unlabelled dot.
    var accessibilityDescription: String? {
        switch self {
        case .caughtUp: nil
        case .unread: "unread"
        case let .mention(count): "\(count) unread, mentions you"
        }
    }
}

/// One sidebar row, fully resolved once per snapshot.
///
/// Everything the row draws is decided here — its section, title, avatar, author
/// prefix, indicator, and even its mention resolver — so the view body performs no
/// name resolution, no store read, and no per-row formatter or resolver construction.
/// That is the scroll-performance half of §8 and §9.
struct SidebarRow: Identifiable {
    /// The navigation value the row pushes. Deliberately still a ``ChannelListRow``,
    /// so the pushed timeline's `navigationDestination(for:)` is unchanged.
    let channel: ChannelListRow
    /// The conversation this row *is*, as the shared resolver sees it.
    let conversation: ConversationIdentity
    let indicator: UnreadIndicator
    /// The preview's author prefix, already human-readable; `nil` when there is no
    /// author to name.
    let authorLabel: String?
    /// The resolver for the preview's `@`/`#` tokens, built once here rather than per
    /// render pass.
    let previewResolver: MessageMentionResolver
    /// The channel's roster, so the row's presence dot is a set test rather than a
    /// lookup back into a model.
    let members: Set<String>

    var id: String { channel.id }
    var section: SidebarSection { SidebarSection.section(for: conversation.kind) }
    /// Always a human-readable name — a channel's name, or the peer's for a DM.
    var title: String { conversation.title }
    var isPrivate: Bool { conversation.isPrivate }
    var date: Date? { channel.lastMessageDate }

    /// The newest message's text, or `nil` for a conversation with nothing in it yet.
    var snippet: String? {
        guard let snippet = channel.lastMessageSnippet, !snippet.isEmpty else { return nil }
        return snippet
    }
}

/// One section as the sidebar draws it.
struct SidebarSectionContent: Identifiable {
    let section: SidebarSection
    /// The section's rows, already ordered.
    let rows: [SidebarRow]

    var id: SidebarSection { section }
    var count: Int { rows.count }
}

/// The whole sidebar, derived from one channel-list snapshot and one directory.
struct SidebarContent {
    /// Only the sections that have rows, in canonical order. A section with nothing in
    /// it is *absent* rather than empty, so an install with no agents never meets an
    /// "Agents" heading (JT's "Agents, when applicable").
    let sections: [SidebarSectionContent]

    static let empty = SidebarContent(sections: [])

    var isEmpty: Bool { sections.isEmpty }

    /// Builds the sidebar.
    ///
    /// - Parameters:
    ///   - channels: the live channel list, in the store's own order.
    ///   - names: the shared resolver — the only source of titles, avatars, kinds, and
    ///     rosters.
    ///   - channelNames: the app-wide `#channel` map, for the preview's `#`-tokens.
    ///   - mentions: the newest message's mention refs for a row, injected so this
    ///     stays a pure function over data the caller already has.
    static func build(
        channels: [ChannelListRow],
        names: EntityNames,
        channelNames: ChannelNameMap,
        mentions: (ChannelListRow) -> [MentionRef]
    ) -> SidebarContent {
        var grouped: [SidebarSection: [SidebarRow]] = [:]
        for channel in channels {
            let refs = mentions(channel)
            let row = SidebarRow(
                channel: channel,
                conversation: names.conversation(for: channel),
                indicator: .resolve(
                    unreadCount: channel.unreadCount,
                    mentionsSelf: mentionsSelf(refs, selfPubkey: names.selfPubkey)
                ),
                authorLabel: authorLabel(
                    channel.lastMessageAuthor,
                    pubkey: channel.lastMessageAuthorPubkey,
                    names: names
                ),
                previewResolver: MessageMentionResolver(
                    // The shared aliasing, not a sidebar-local copy: the timeline and a
                    // thread build their per-message resolver through the same call, so a
                    // profile-less mention resolves identically on all three.
                    mentions: names.aliased(refs),
                    channels: channelNames,
                    selfPubkey: names.selfPubkey
                ),
                members: names.members(of: channel.id)
            )
            grouped[row.section, default: []].append(row)
        }

        let sections = SidebarSection.allCases.compactMap { section -> SidebarSectionContent? in
            guard let rows = grouped[section], !rows.isEmpty else { return nil }
            return SidebarSectionContent(section: section, rows: rows.sorted(by: precedes))
        }
        return SidebarContent(sections: sections)
    }
}

// MARK: - Ordering

extension SidebarContent {
    /// Newest activity first, conversations with nothing in them last, then by the
    /// *rendered* title, and finally by id so the order is total and stable.
    ///
    /// The store's own `channelList()` ordering breaks ties on the **channel's** name,
    /// which for a DM is not the name the sidebar shows. Re-sorting inside a section on
    /// the resolved title is what keeps a quiet list of DMs alphabetical by person
    /// rather than by whatever the relay called the group.
    static func precedes(_ lhs: SidebarRow, _ rhs: SidebarRow) -> Bool {
        switch (lhs.channel.lastMessageAt, rhs.channel.lastMessageAt) {
        case let (left?, right?) where left != right:
            return left > right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            break
        }
        let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

// MARK: - Preview resolution

extension SidebarContent {
    /// The author prefix for a row's preview, guaranteed human-readable.
    ///
    /// The chain is ``TimelineRowView``'s, so the same person prefixes a preview here and
    /// heads a message there: the shared directory first — which reaches the agent name,
    /// the NIP-05 username, and finally the short `npub1…` form that a profile-only
    /// projection cannot — then the display name the row itself carries, for an identity
    /// the directory has no entry for, and the short identifier as the floor.
    ///
    /// It takes the author's **key** as well as the label because
    /// ``ChannelListRow/lastMessageAuthor`` is *either* a kind-0 display name *or* the raw
    /// pubkey, and telling those apart by shape (64 hex characters) is a guess that a user
    /// whose display name happens to be 64 hex characters loses — the row then showed them
    /// a fabricated, plausible-looking `npub1…` for someone else. With the key in hand the
    /// test is an equality, not a heuristic.
    ///
    /// An absent author with no key yields `nil` and the row simply shows the message.
    static func authorLabel(_ author: String?, pubkey: String?, names: EntityNames) -> String? {
        let carried = author?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard let pubkey, !pubkey.isEmpty else {
            return carried.isEmpty ? nil : carried
        }
        if let human = names.humanName(for: pubkey) { return human }
        if !carried.isEmpty, carried.lowercased() != pubkey.lowercased() { return carried }
        return names.shortIdentifier(for: pubkey)
    }

    /// Whether any of a message's mentions is the local identity.
    static func mentionsSelf(_ refs: [MentionRef], selfPubkey: String?) -> Bool {
        guard let selfPubkey, !selfPubkey.isEmpty else { return false }
        let key = selfPubkey.lowercased()
        return refs.contains { $0.pubkey.lowercased() == key }
    }
}
