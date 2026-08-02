import BuzzKit
import Foundation

/// The sidebar's groupings: Starred, then Channels, DMs, Agents.
///
/// Three of the four are *derived*, never stored: which one a conversation lands in is
/// a projection of ``ConversationIdentity/Kind``, which the foundation already decided
/// from the roster. There is no second classifier here.
///
/// ``starred`` is the exception, and deliberately so — it is the one grouping that is
/// not a fact about the conversation but a choice the reader made about it, held on this
/// device (see ``StarredConversations``). It is not a fifth kind: a starred conversation
/// keeps its kind, its title, and its mark, and only its heading changes.
enum SidebarSection: String, CaseIterable, Hashable, Sendable, Identifiable {
    case starred
    case channels
    case directMessages
    case agents

    var id: String { rawValue }

    /// The header's label.
    var title: String {
        switch self {
        case .starred: "Starred"
        case .channels: "Channels"
        case .directMessages: "DMs"
        case .agents: "Agents"
        }
    }

    /// What the section's `+` says to a screen reader. Only Channels draws one, but the
    /// words live here with the rest of the section's vocabulary rather than at the one
    /// call site, so a second addable section cannot be labelled "New channel".
    var createLabel: String {
        switch self {
        case .starred: "New starred conversation"
        case .channels: "New channel"
        case .directMessages: "New direct message"
        case .agents: "New agent"
        }
    }

    /// The SF Symbol that makes this section recognizable before its title is read.
    var symbol: String {
        switch self {
        case .starred: "star.fill"
        case .channels: "number"
        case .directMessages: "bubble.left.and.text.bubble.right"
        case .agents: "sparkles"
        }
    }

    /// The column that keeps every header title on one leading edge.
    ///
    /// Measured, not chosen. The widest of the four is
    /// `bubble.left.and.text.bubble.right`, which renders **34.67 points** wide at the
    /// header's `.title3` bold configuration — so this started at 32 and the test below
    /// failed it. That is the point of having the test: a SwiftUI `.frame` does not clip, so a
    /// column narrower than its glyph does not look wrong here, it silently pushes that one
    /// symbol out into the 8-point gap and sets "DMs" closer to its icon than "Channels"
    /// is to the `#`.
    ///
    /// The test measures every section glyph at that same configuration and asserts this
    /// contains it, so changing a symbol, the text style, or the weight cannot quietly
    /// reintroduce the overlap.
    static let symbolColumnWidth: CGFloat = 36

    /// Whether this heading stays on screen with nothing underneath it.
    ///
    /// Only DMs. The other three are *discovered* — you learn the app has Agents by
    /// meeting one — so an empty heading there is a promise about the product rather
    /// than a fact about your account, and Agents in particular is "when applicable".
    /// A person's DMs are different: the absence is the information. Somebody freshly
    /// joined to a community, which after an invite is everybody, needs to see that
    /// they have no conversations yet rather than be left to wonder whether the app
    /// has DMs at all or has simply not loaded them.
    ///
    /// This is the section's own disposition and not the whole rule —
    /// ``SidebarContent/build(channels:names:starred:)`` also requires a sidebar with
    /// something else in it and a reader with a key, for the reasons stated there.
    var persistsWhenEmpty: Bool { self == .directMessages }

    /// What stands in for the rows when a persistent section has none.
    var emptyMessage: String {
        switch self {
        case .directMessages: "No direct messages yet"
        case .starred: "Nothing starred yet"
        case .channels: "No channels yet"
        case .agents: "No agents yet"
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
    /// including me", "an agent DM is one whose peer is an agent", "a group DM is one the
    /// relay calls a DM with more people than that in it" — live once, in
    /// ``EntityNames/conversation(for:)``. This function only maps the answer onto a
    /// heading.
    static func section(for kind: ConversationIdentity.Kind) -> SidebarSection {
        switch kind {
        case .channel: .channels
        // A group DM files with the other direct messages rather than under a heading of
        // its own: it is the same kind of conversation with more people in it, and a
        // fifth section holding one or two rows is a heading that costs more than it says.
        case .direct, .group: .directMessages
        case .agent: .agents
        }
    }
}

/// How one row advertises unread activity.
///
/// Two *visually distinct* states, the pattern Slack and the Buzz Flutter client share:
/// a name in bold for "there is something new in here", a numeric badge for "this many
/// of them are addressed to you". Folding both into one badge is exactly what makes a
/// mention easy to walk past.
enum UnreadIndicator: Hashable, Sendable {
    /// Caught up — nothing drawn.
    ///
    /// Deliberately not spelled `none`: an enum case by that name is shadowed by
    /// `Optional.none` at every comparison site, so `dictionary[key] == .none` silently
    /// asks whether the *lookup* failed instead of whether the row is read.
    case caughtUp
    /// Unread messages, none of which mention the local identity. The bolded name is the
    /// whole signal; there is no separate dot beside it.
    case unread
    /// How many unread messages mention the local identity: a numeric badge.
    case mention(Int)
    /// How many unread messages are waiting in a one-to-one conversation: the same badge,
    /// counting all of them.
    ///
    /// A DM has nobody else in it. Every message in one is addressed to you whether or not
    /// it spells your name, so the mention rule — which exists to pick your messages out of
    /// a room's traffic — has nothing to pick out and would leave a DM with only a bolded
    /// name. Separate from ``mention(_:)`` because the two are the same badge saying
    /// different things, and a screen reader has to say which.
    case directUnread(Int)

    /// The indicator for a conversation's unread count and how many of those unread
    /// messages address the local identity.
    ///
    /// Both numbers come from one ``BuzzKit/ChannelListRow``, counted over the same set
    /// by the same query — so the badge cannot claim more mentions than the row has
    /// unread messages, and a mention in an older-but-still-unread message counts
    /// exactly like a mention in the newest one. (Until Part 6 the answer could only be
    /// read from the *newest* message's `p` tags, so an older unread mention showed as a
    /// plain dot and the badge borrowed the unread count for its number.)
    ///
    /// - Parameter isDirect: whether this is a direct message — with a person, with an
    ///   agent, or with a few people. None of them is a room you are in for the traffic,
    ///   so all of them count every message.
    /// - Parameter isMuted: whether the reader has muted this conversation. A muted row
    ///   reads exactly as a caught-up one — no bold name, no badge — which is the whole
    ///   of what mute can mean in a client with no push notifications.
    ///
    ///   Unconditional, deliberately: a mention inside a muted channel is suppressed
    ///   here too. Slack keeps the mention badge, and that is a defensible other answer
    ///   — but the row's copy says it suppresses the unread badge, and a mute with an
    ///   exception is a mute the reader has to remember the rules of. Nothing is lost:
    ///   the mention still reaches the Activity tab, which exists to be the one place
    ///   nothing is filtered out of.
    static func resolve(
        unreadCount: Int,
        mentionCount: Int,
        isDirect: Bool,
        isMuted: Bool = false
    ) -> UnreadIndicator {
        guard unreadCount > 0, !isMuted else { return .caughtUp }
        if isDirect { return .directUnread(unreadCount) }
        return mentionCount > 0 ? .mention(mentionCount) : .unread
    }

    /// Whether the row should read as unread — a bolder, full-strength name.
    var isUnread: Bool { self != .caughtUp }

    /// The badge's text, capped so a very busy channel never widens the row. `nil` for
    /// the states that draw no badge.
    var badgeText: String? {
        switch self {
        case .caughtUp, .unread: nil
        case let .mention(count), let .directUnread(count): count > 99 ? "99+" : "\(count)"
        }
    }

    /// The spoken form, folded into the row's combined label so VoiceOver does not
    /// meet an unlabelled badge.
    var accessibilityDescription: String? {
        switch self {
        case .caughtUp: nil
        case .unread: "unread"
        case let .mention(count): count == 1 ? "1 mention" : "\(count) mentions"
        case let .directUnread(count): count == 1 ? "1 new message" : "\(count) new messages"
        }
    }
}

/// One sidebar row, fully resolved once per snapshot.
///
/// Everything the row draws is decided here — its section, title, mark, and indicator —
/// so the view body performs no name resolution and no store read. That is the
/// scroll-performance half of §8 and §9.
///
/// # What a row no longer carries
///
/// A message preview, its author prefix, its own mention resolver, and its timestamp.
/// The Slack-style list shows a conversation's *name* and whether it wants you, and
/// nothing else — so the resolver a preview needed is not built, the snippet is not
/// styled, and the shared clock is not read once per row. What used to be the most
/// expensive part of a sidebar snapshot is now absent rather than optimised.
struct SidebarRow: Identifiable {
    /// The navigation value the row pushes. Deliberately still a ``ChannelListRow``,
    /// so the pushed timeline's `navigationDestination(for:)` is unchanged.
    let channel: ChannelListRow
    /// The conversation this row *is*, as the shared resolver sees it.
    let conversation: ConversationIdentity
    let indicator: UnreadIndicator
    /// Whether the reader has starred this conversation on this device. Decided here so
    /// the row's swipe action and its heading agree without either consulting the store
    /// of stars a second time.
    let isStarred: Bool

    var id: String { channel.id }
    /// A starred conversation is filed under its star rather than under its kind — the
    /// Slack rule, and the reason the section is worth having: it is not a copy of the
    /// row that also appears below, it is where the row now lives.
    var section: SidebarSection {
        isStarred ? .starred : SidebarSection.section(for: conversation.kind)
    }

    /// Always a human-readable name — a channel's name, or the peer's for a DM.
    var title: String { conversation.title }
    var isPrivate: Bool { conversation.isPrivate }
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
    /// The sections to draw, in canonical order.
    ///
    /// A section with nothing in it is *absent* rather than empty — so an install with
    /// no agents never meets an "Agents" heading (JT's "Agents, when applicable") —
    /// with the single exception of the one that ``SidebarSection/persistsWhenEmpty``
    /// names, which stays and shows its ``SidebarSection/emptyMessage``.
    let sections: [SidebarSectionContent]

    static let empty = SidebarContent(sections: [])

    var isEmpty: Bool { sections.isEmpty }

    /// Builds the sidebar.
    ///
    /// - Parameters:
    ///   - channels: the live channel list, in the store's own order.
    ///   - names: the shared resolver — the only source of titles, avatars, kinds, and
    ///     rosters.
    ///   - starred: the conversation ids the reader has starred on this device.
    static func build(
        channels: [ChannelListRow],
        names: EntityNames,
        starred: Set<String> = []
    ) -> SidebarContent {
        var grouped: [SidebarSection: [SidebarRow]] = [:]
        for channel in channels {
            let conversation = names.conversation(for: channel)
            let row = SidebarRow(
                channel: channel,
                conversation: conversation,
                indicator: .resolve(
                    unreadCount: channel.unreadCount,
                    mentionCount: channel.unreadMentionCount,
                    // The one thing that decides which rule a row is counted by, taken from
                    // the same resolved identity the row is titled and filed by — so a
                    // conversation cannot be a DM in the sidebar's heading and a channel in
                    // its badge.
                    isDirect: conversation.isDirect,
                    isMuted: channel.isMuted
                ),
                isStarred: starred.contains(channel.id)
            )
            grouped[row.section, default: []].append(row)
        }

        // A persistent heading earns its place only in a sidebar that is otherwise
        // populated, and only for a reader who could have the thing it names:
        //
        // - **Nothing at all** stays *nothing at all*. A lone "DMs — none yet" over a
        //   blank sidebar is a worse answer than the whole-list empty state, which says
        //   the same thing about everything rather than about one heading.
        // - **A session with no key** cannot tell a DM from a channel — the roster rule
        //   in ``EntityNames`` needs to find *you* in the roster — so every conversation
        //   files under Channels and the DMs heading could never fill. Promising an
        //   empty section that is structurally unfillable is worse than omitting it.
        let sidebarHasRows = !grouped.isEmpty
        let viewerIsIdentified = names.selfPubkey != nil
        let sections = SidebarSection.allCases.compactMap { section -> SidebarSectionContent? in
            let rows = grouped[section] ?? []
            let persists = section.persistsWhenEmpty && sidebarHasRows && viewerIsIdentified
            guard !rows.isEmpty || persists else { return nil }
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

// The author prefix and the per-row mention resolver that used to live here went with
// the preview line they served. Whether a row's unread messages mention you is no longer
// inferred from the newest message's `p` tags either — ``BuzzKit/ChannelListRow`` counts
// it directly, over the same set it counts unread messages over.
