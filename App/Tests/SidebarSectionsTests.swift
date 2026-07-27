@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// The Phase-5 §8 sidebar contract: section classification from rosters, order inside
/// a section, the unread-versus-mention decision, the author prefix, and the persisted
/// expansion defaults.
///
/// Everything here is pure — the point of keeping the derivation in ``SidebarContent``
/// rather than in a view body is that these decisions are asserted rather than
/// eyeballed on a simulator.
@Suite("Sidebar sections", .timeLimit(.minutes(1)))
struct SidebarSectionsTests {
    /// A valid 32-byte key, so any short form exercises the real bech32 path.
    static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    let me = key(0x11)
    let peer = key(0x22)
    let agent = key(0x33)
    let other = key(0x44)

    // MARK: - Fixtures

    func names(
        entities: [DirectoryEntity],
        rosters: [String: Set<String>] = [:],
        channels: [ChannelListRow] = [],
        selfPubkey: String? = nil
    ) -> EntityNames {
        EntityNames(
            snapshot: DirectorySnapshot(
                entities: Dictionary(uniqueKeysWithValues: entities.map { ($0.pubkey, $0) }),
                memberPubkeysByChannel: rosters
            ),
            channels: channels,
            selfPubkey: selfPubkey
        )
    }

    func channel(
        _ id: String,
        name: String? = nil,
        isPrivate: Bool = false,
        lastMessageAt: Int64? = nil,
        author: String? = nil,
        authorPubkey: String? = nil,
        snippet: String? = nil,
        unreadCount: Int = 0,
        unreadMentionCount: Int = 0
    ) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: isPrivate,
            lastMessageAt: lastMessageAt,
            lastMessageID: lastMessageAt == nil ? nil : "msg-\(id)",
            lastMessageSnippet: snippet,
            lastMessageAuthor: author,
            lastMessageAuthorPubkey: authorPubkey,
            unreadCount: unreadCount,
            unreadMentionCount: unreadMentionCount
        )
    }

    func build(
        _ channels: [ChannelListRow],
        names: EntityNames,
        starred: Set<String> = []
    ) -> SidebarContent {
        SidebarContent.build(channels: channels, names: names, starred: starred)
    }
}

// MARK: - Classification

extension SidebarSectionsTests {
    @Test("classifies channels, direct messages, and agent DMs from the same roster rule")
    func classification() {
        let rows = [
            channel("general", name: "General"),
            channel("dm-peer", name: "dm"),
            channel("dm-agent", name: "dm"),
            channel("threesome", name: "Trio"),
        ]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: peer, profileName: "Ada"),
                DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
                DirectoryEntity(pubkey: other, profileName: "Third"),
            ],
            rosters: [
                "general": [me, peer, agent, other],
                "dm-peer": [me, peer],
                "dm-agent": [me, agent],
                "threesome": [me, peer, other],
            ],
            channels: rows,
            selfPubkey: me
        )

        let content = build(rows, names: resolver)
        #expect(content.sections.map(\.section) == [.channels, .directMessages, .agents])
        #expect(content.sections[0].rows.map(\.id) == ["general", "threesome"])
        // A DM is titled by the person, not by whatever the relay called the group.
        #expect(content.sections[1].rows.map(\.title) == ["Ada"])
        #expect(content.sections[2].rows.map(\.title) == ["Jarvis"])
        #expect(content.sections[2].rows[0].conversation.peer == agent)
    }

    @Test("a section with no rows is absent, not empty")
    func emptySectionsAreHidden() {
        let rows = [channel("general", name: "General")]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            rosters: ["general": [me, peer, other]],
            channels: rows,
            selfPubkey: me
        )

        let content = build(rows, names: resolver)
        #expect(content.sections.map(\.section) == [.channels])
        #expect(!content.isEmpty)
        #expect(build([], names: resolver).isEmpty)
        #expect(SidebarContent.empty.isEmpty)
    }

    @Test("a keyless session cannot tell a DM from a channel, so everything is a channel")
    func keylessSessionHasNoDirectMessages() {
        let rows = [channel("dm-peer", name: "dm"), channel("general", name: "General")]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: peer, profileName: "Ada")],
            rosters: ["dm-peer": [me, peer], "general": [me, peer, other]],
            channels: rows
        )

        let content = build(rows, names: resolver)
        #expect(content.sections.map(\.section) == [.channels])
        #expect(content.sections[0].rows.count == 2)
    }

    @Test("a section is a projection of the conversation kind, not a second guess")
    func sectionForKind() {
        #expect(SidebarSection.section(for: .channel) == .channels)
        #expect(SidebarSection.section(for: .direct) == .directMessages)
        #expect(SidebarSection.section(for: .agent) == .agents)
        // Starred leads: it is the shortlist, and a shortlist below the full list is a
        // second list rather than a shortcut.
        #expect(SidebarSection.allCases == [.starred, .channels, .directMessages, .agents])
        #expect(SidebarSection.starred.title == "Starred")
        #expect(SidebarSection.channels.title == "Channels")
        #expect(SidebarSection.directMessages.title == "Direct Messages")
        #expect(SidebarSection.agents.title == "Agents")
    }
}

// MARK: - Unread versus mention

extension SidebarSectionsTests {
    @Test("a bold name for ordinary unread, a numeric badge for the messages addressed to you")
    func unreadVersusMention() {
        #expect(UnreadIndicator.resolve(unreadCount: 0, mentionCount: 0) == .caughtUp)
        // A mention with nothing unread is already read: no indicator at all. The counts
        // come from one query over one set, so this state should not arise — it is
        // resolved rather than trusted, because a badge on a read row is unexplainable.
        #expect(UnreadIndicator.resolve(unreadCount: 0, mentionCount: 2) == .caughtUp)
        #expect(UnreadIndicator.resolve(unreadCount: 3, mentionCount: 0) == .unread)
        // The badge shows the *mention* count, not the unread count it is a subset of.
        #expect(UnreadIndicator.resolve(unreadCount: 5, mentionCount: 2) == .mention(2))

        #expect(UnreadIndicator.caughtUp.isUnread == false)
        #expect(UnreadIndicator.unread.isUnread)
        #expect(UnreadIndicator.mention(1).isUnread)

        // Only the badge draws a number, and it is capped so a busy channel never
        // widens the row.
        #expect(UnreadIndicator.caughtUp.badgeText == nil)
        #expect(UnreadIndicator.unread.badgeText == nil)
        #expect(UnreadIndicator.mention(7).badgeText == "7")
        #expect(UnreadIndicator.mention(100).badgeText == "99+")

        #expect(UnreadIndicator.caughtUp.accessibilityDescription == nil)
        #expect(UnreadIndicator.unread.accessibilityDescription == "unread")
        #expect(UnreadIndicator.mention(1).accessibilityDescription == "1 mention")
        #expect(UnreadIndicator.mention(2).accessibilityDescription == "2 mentions")
    }

    @Test("the indicator is the row's own unread and mention counts, not a guess from one message")
    func indicatorFromRowCounts() {
        let rows = [
            channel("mentions-me", name: "Mentions", lastMessageAt: 3_000,
                    unreadCount: 5, unreadMentionCount: 2),
            channel("mentions-other", name: "Other", lastMessageAt: 2_000, unreadCount: 5),
            channel("caught-up", name: "Quiet", lastMessageAt: 1_000, unreadCount: 0),
        ]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            channels: rows,
            selfPubkey: me
        )

        let byID = Dictionary(uniqueKeysWithValues: build(rows, names: resolver)
            .sections[0].rows.map { ($0.id, $0.indicator) })
        // Two mentions inside five unread messages: the badge counts the mentions. Until
        // Part 6 this row could only show `5`, because the count it had was the unread one.
        #expect(byID["mentions-me"] == .mention(2))
        #expect(byID["mentions-other"] == .unread)
        #expect(byID["caught-up"] == .caughtUp)
    }
}

// MARK: - What a row carries

extension SidebarSectionsTests {
    @Test("a row carries a resolved title, roster, and indicator with no view work left")
    func rowIsFullyResolved() {
        let rows = [channel(
            "general",
            name: "General",
            isPrivate: true,
            lastMessageAt: 4_000,
            author: agent,
            authorPubkey: agent,
            snippet: "shipping now",
            unreadCount: 1
        )]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            ],
            rosters: ["general": [me, agent, other]],
            channels: rows,
            selfPubkey: me
        )

        let row = build(rows, names: resolver, starred: ["general"]).sections[0].rows[0]
        #expect(row.title == "General")
        #expect(row.isPrivate)
        #expect(row.members == [me, agent, other])
        #expect(row.indicator == .unread)
        #expect(row.isStarred)
        #expect(row.section == .starred)
        // The navigation value is still the store's own row, so the pushed timeline's
        // destination is unchanged — and it still carries the snippet the sidebar has
        // stopped drawing, because the pushed timeline is what reads it.
        #expect(row.channel == rows[0])
        #expect(row.channel.lastMessageSnippet == "shipping now")
    }

    // The preview line, its author prefix, and its per-row mention resolver are gone with
    // the Slack-style row (Part 6) — `SidebarContent.authorLabel`/`mentionsSelf` and the
    // tests that pinned them went with them. The aliasing they shared still lives on
    // ``EntityNames`` and is asserted there.
}

// MARK: - Persisted expansion

extension SidebarSectionsTests {
    @Test("expansion defaults to open and its defaults keys are pinned")
    func expansionDefaults() {
        #expect(SidebarSection.defaultIsExpanded)
        // Pinned strings: renaming one silently discards the expansion state every
        // existing install has chosen, and nothing else would catch it.
        #expect(SidebarSection.starred.expansionStorageKey == "sidebar.section.starred.expanded")
        #expect(SidebarSection.channels.expansionStorageKey == "sidebar.section.channels.expanded")
        #expect(
            SidebarSection.directMessages.expansionStorageKey
                == "sidebar.section.directMessages.expanded"
        )
        #expect(SidebarSection.agents.expansionStorageKey == "sidebar.section.agents.expanded")
        #expect(Set(SidebarSection.allCases.map(\.expansionStorageKey)).count == SidebarSection.allCases.count)
    }
}
