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
    private static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private let me = key(0x11)
    private let peer = key(0x22)
    private let agent = key(0x33)
    private let other = key(0x44)

    // MARK: - Fixtures

    private func names(
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

    private func channel(
        _ id: String,
        name: String? = nil,
        isPrivate: Bool = false,
        lastMessageAt: Int64? = nil,
        author: String? = nil,
        snippet: String? = nil,
        unreadCount: Int = 0
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
            unreadCount: unreadCount
        )
    }

    private func build(
        _ channels: [ChannelListRow],
        names: EntityNames,
        mentions: [String: [MentionRef]] = [:]
    ) -> SidebarContent {
        SidebarContent.build(
            channels: channels,
            names: names,
            channelNames: .empty,
            mentions: { mentions[$0.id] ?? [] }
        )
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
        #expect(SidebarSection.allCases == [.channels, .directMessages, .agents])
        #expect(SidebarSection.channels.title == "Channels")
        #expect(SidebarSection.directMessages.title == "Direct Messages")
        #expect(SidebarSection.agents.title == "Agents")
    }
}

// MARK: - Ordering

extension SidebarSectionsTests {
    @Test("orders newest first inside a section, messageless last, then by rendered title")
    func ordering() {
        let rows = [
            channel("zulu", name: "Zulu", lastMessageAt: nil),
            channel("alpha", name: "Alpha", lastMessageAt: nil),
            channel("older", name: "Older", lastMessageAt: 1_000),
            channel("newer", name: "Newer", lastMessageAt: 2_000),
        ]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            channels: rows,
            selfPubkey: me
        )

        let ordered = build(rows, names: resolver).sections[0].rows.map(\.id)
        #expect(ordered == ["newer", "older", "alpha", "zulu"])
    }

    @Test("a DM sorts on the peer's name, not the group's, and ties break on id")
    func orderingUsesRenderedTitle() {
        let rows = [
            channel("dm-b", name: "zzz-group"),
            channel("dm-a", name: "aaa-group"),
        ]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: peer, profileName: "Ada"),
                DirectoryEntity(pubkey: agent, profileName: "Zoe"),
            ],
            rosters: ["dm-b": [me, peer], "dm-a": [me, agent]],
            channels: rows,
            selfPubkey: me
        )

        // `dm-b` is named "zzz-group" but is a DM with Ada, so it sorts first.
        #expect(build(rows, names: resolver).sections[0].rows.map(\.title) == ["Ada", "Zoe"])

        // Same timestamp and same rendered title: the group id is the last resort, so
        // the order is total and does not flicker between reads.
        let ambiguous = [
            channel("b-id", name: "Same", lastMessageAt: 5),
            channel("a-id", name: "Same", lastMessageAt: 5),
        ]
        let plain = names(entities: [], channels: ambiguous)
        #expect(build(ambiguous, names: plain).sections[0].rows.map(\.id) == ["a-id", "b-id"])
    }
}

// MARK: - Unread versus mention

extension SidebarSectionsTests {
    @Test("a dot for ordinary unread, a numeric pill when the unread messages mention you")
    func unreadVersusMention() {
        #expect(UnreadIndicator.resolve(unreadCount: 0, mentionsSelf: false) == .caughtUp)
        // A mention with nothing unread is already read: no indicator at all.
        #expect(UnreadIndicator.resolve(unreadCount: 0, mentionsSelf: true) == .caughtUp)
        #expect(UnreadIndicator.resolve(unreadCount: 3, mentionsSelf: false) == .unread)
        #expect(UnreadIndicator.resolve(unreadCount: 3, mentionsSelf: true) == .mention(3))

        #expect(UnreadIndicator.caughtUp.isUnread == false)
        #expect(UnreadIndicator.unread.isUnread)
        #expect(UnreadIndicator.mention(1).isUnread)

        // Only the pill draws a number, and it is capped so a busy channel never
        // widens the row.
        #expect(UnreadIndicator.caughtUp.badgeText == nil)
        #expect(UnreadIndicator.unread.badgeText == nil)
        #expect(UnreadIndicator.mention(7).badgeText == "7")
        #expect(UnreadIndicator.mention(100).badgeText == "99+")

        #expect(UnreadIndicator.caughtUp.accessibilityDescription == nil)
        #expect(UnreadIndicator.unread.accessibilityDescription == "unread")
        #expect(UnreadIndicator.mention(2).accessibilityDescription == "2 unread, mentions you")
    }

    @Test("the indicator comes from the newest message's mentions of the local identity")
    func indicatorFromMentions() {
        let rows = [
            channel("mentions-me", name: "Mentions", lastMessageAt: 3_000, unreadCount: 2),
            channel("mentions-other", name: "Other", lastMessageAt: 2_000, unreadCount: 5),
            channel("caught-up", name: "Quiet", lastMessageAt: 1_000, unreadCount: 0),
        ]
        let resolver = names(
            entities: [DirectoryEntity(pubkey: me, profileName: "Me")],
            channels: rows,
            selfPubkey: me.uppercased()
        )
        let content = build(rows, names: resolver, mentions: [
            // The stored ref carries the key upper-cased; matching is case-insensitive.
            "mentions-me": [MentionRef(pubkey: me.uppercased(), displayName: "Me")],
            "mentions-other": [MentionRef(pubkey: other, displayName: "Third")],
            "caught-up": [MentionRef(pubkey: me, displayName: "Me")],
        ])

        let byID = Dictionary(uniqueKeysWithValues: content.sections[0].rows.map { ($0.id, $0.indicator) })
        #expect(byID["mentions-me"] == .mention(2))
        #expect(byID["mentions-other"] == .unread)
        #expect(byID["caught-up"] == .caughtUp)
    }

    @Test("a keyless session never claims a mention")
    func mentionsSelfNeedsAnIdentity() {
        let refs = [MentionRef(pubkey: me, displayName: "Me")]
        #expect(SidebarContent.mentionsSelf(refs, selfPubkey: nil) == false)
        #expect(SidebarContent.mentionsSelf(refs, selfPubkey: "") == false)
        #expect(SidebarContent.mentionsSelf(refs, selfPubkey: me.uppercased()))
        #expect(SidebarContent.mentionsSelf([], selfPubkey: me) == false)
    }
}

// MARK: - Names in the preview

extension SidebarSectionsTests {
    @Test("the preview's author prefix is never a raw key")
    func authorPrefixResolvesThroughTheDirectory() {
        let resolver = names(entities: [
            DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            DirectoryEntity(pubkey: peer, nip05: "ada@buzz.dev"),
        ])

        // A display name the store already resolved passes through untouched.
        #expect(SidebarContent.authorLabel("Ada Lovelace", names: resolver) == "Ada Lovelace")
        // The raw-key fallback resolves through the directory, which reaches the agent
        // name and the NIP-05 username a profile-only projection cannot.
        #expect(SidebarContent.authorLabel(agent, names: resolver) == "Jarvis")
        #expect(SidebarContent.authorLabel(peer, names: resolver) == "ada")
        // Nothing known: a short npub, never the 64-character key.
        let unknown = SidebarContent.authorLabel(other, names: resolver)
        #expect(unknown?.hasPrefix("npub1") == true)
        #expect(unknown?.contains(other) == false)
        // No author to name at all.
        #expect(SidebarContent.authorLabel(nil, names: resolver) == nil)
        #expect(SidebarContent.authorLabel("   ", names: resolver) == nil)

        #expect(SidebarContent.isHexKey(other))
        #expect(SidebarContent.isHexKey("Ada Lovelace") == false)
        #expect(SidebarContent.isHexKey(String(repeating: "z", count: 64)) == false)
    }

    @Test("a row carries a resolved title, author prefix, and roster with no view work left")
    func rowIsFullyResolved() {
        let rows = [channel(
            "general",
            name: "General",
            isPrivate: true,
            lastMessageAt: 4_000,
            author: agent,
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

        let row = build(rows, names: resolver).sections[0].rows[0]
        #expect(row.title == "General")
        #expect(row.isPrivate)
        #expect(row.authorLabel == "Jarvis")
        #expect(row.snippet == "shipping now")
        #expect(row.members == [me, agent, other])
        #expect(row.date == Date(timeIntervalSince1970: 4_000))
        #expect(row.indicator == .unread)
        #expect(row.section == .channels)
        // The navigation value is still the store's own row, so the pushed timeline's
        // destination is unchanged.
        #expect(row.channel == rows[0])
    }

    @Test("an empty snippet reads as no messages rather than a blank line")
    func emptySnippet() {
        let rows = [channel("general", name: "General", lastMessageAt: 10, snippet: "")]
        let resolver = names(entities: [], channels: rows)
        #expect(build(rows, names: resolver).sections[0].rows[0].snippet == nil)
    }

    @Test("mention refs gain the directory's own name as a second alias")
    func mentionRefsMergeDirectoryNames() {
        let resolver = names(entities: [
            DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            DirectoryEntity(pubkey: peer, profileName: "Ada"),
        ])

        // BuzzKit fell back to `pubkey.prefix(8)`; the directory knows the agent's name,
        // so both spellings register and the preview's `@`-scan can match either.
        let merged = SidebarContent.mentionRefs(
            [
                MentionRef(pubkey: agent, displayName: String(agent.prefix(8))),
                MentionRef(pubkey: peer, displayName: "Ada"),
            ],
            names: resolver
        )
        #expect(merged.map(\.displayName) == [String(agent.prefix(8)), "Ada", "Jarvis"])
        // Originals come first, so the store's authored order still wins a collision.
        #expect(merged.prefix(2).map(\.pubkey) == [agent, peer])
    }
}

// MARK: - Persisted expansion

extension SidebarSectionsTests {
    @Test("expansion defaults to open and its defaults keys are pinned")
    func expansionDefaults() {
        #expect(SidebarSection.defaultIsExpanded)
        // Pinned strings: renaming one silently discards the expansion state every
        // existing install has chosen, and nothing else would catch it.
        #expect(SidebarSection.channels.expansionStorageKey == "sidebar.section.channels.expanded")
        #expect(
            SidebarSection.directMessages.expansionStorageKey
                == "sidebar.section.directMessages.expanded"
        )
        #expect(SidebarSection.agents.expansionStorageKey == "sidebar.section.agents.expanded")
        #expect(Set(SidebarSection.allCases.map(\.expansionStorageKey)).count == SidebarSection.allCases.count)
    }
}
