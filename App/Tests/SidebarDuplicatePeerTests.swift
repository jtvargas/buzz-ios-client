@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// One row per person, however many conversations the relay holds with them.
///
/// The defect, measured on the homelab relay 2026-08-06: 25 two-member DM channels for
/// only 18 distinct pairs, three of them holding the same two people. Rotating an agent's
/// key moves its DM to the replacement instead of merging it into the conversation the
/// pair already had, and the rows that result are indistinguishable on screen — same
/// name, same avatar, same dot.
@Suite("Sidebar duplicate peers", .timeLimit(.minutes(1)))
struct SidebarDuplicatePeerTests {
    /// A valid 32-byte key, so any short form exercises the real bech32 path.
    static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    let me = key(0x11)
    let peer = key(0x22)
    let agent = key(0x33)
    let other = key(0x44)
    /// A second person whose profile name collides with ``peer``'s — the case the
    /// collapse must *not* fire on.
    let twin = key(0x55)

    // MARK: - Fixtures

    /// A conversation the relay calls a direct message, which is what makes a roster of
    /// three a group rather than a private channel.
    func dm(_ id: String, lastMessageAt: Int64? = nil) -> ChannelListRow {
        row(id, name: "DM", lastMessageAt: lastMessageAt, channelType: "dm")
    }

    func row(
        _ id: String,
        name: String,
        lastMessageAt: Int64? = nil,
        channelType: String? = nil
    ) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: true,
            lastMessageAt: lastMessageAt,
            lastMessageID: lastMessageAt == nil ? nil : "msg-\(id)",
            lastMessageSnippet: nil,
            lastMessageAuthor: nil,
            channelType: channelType
        )
    }

    func build(
        _ channels: [ChannelListRow],
        entities: [DirectoryEntity],
        rosters: [String: Set<String>],
        starred: Set<String> = []
    ) -> SidebarContent {
        let names = EntityNames(
            snapshot: DirectorySnapshot(
                entities: Dictionary(uniqueKeysWithValues: entities.map { ($0.pubkey, $0) }),
                memberPubkeysByChannel: rosters
            ),
            channels: channels,
            selfPubkey: me
        )
        return SidebarContent.build(channels: channels, names: names, starred: starred)
    }

    func rows(_ sidebar: SidebarContent, _ section: SidebarSection) -> [String]? {
        sidebar.sections.first { $0.section == section }?.rows.map(\.id)
    }

    var people: [DirectoryEntity] {
        [
            DirectoryEntity(pubkey: me, profileName: "Me"),
            DirectoryEntity(pubkey: peer, profileName: "Ada"),
            DirectoryEntity(pubkey: other, profileName: "Third"),
        ]
    }
}

// MARK: - Collapsing

extension SidebarDuplicatePeerTests {
    @Test("several conversations with one person draw one row")
    func duplicateDirectMessagesCollapse() {
        let sidebar = build(
            [dm("dm-old", lastMessageAt: 100), dm("dm-new", lastMessageAt: 900)],
            entities: people,
            rosters: ["dm-old": [me, peer], "dm-new": [me, peer]]
        )

        // The conversation somebody is actually in is the one a tap should reach.
        #expect(rows(sidebar, .directMessages) == ["dm-new"])
        #expect(sidebar.sections.first { $0.section == .directMessages }?.rows.map(\.title)
            == ["Ada"])
    }

    @Test("an agent's duplicated DMs collapse in the Agents section too")
    func duplicateAgentDirectMessagesCollapse() {
        let sidebar = build(
            [dm("agent-old", lastMessageAt: 800), dm("agent-new", lastMessageAt: 200)],
            entities: people + [DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true)],
            rosters: ["agent-old": [me, agent], "agent-new": [me, agent]]
        )

        // Newest wins wherever the row is filed, and the freshly created channel is not
        // automatically the live one — here the older id carries the conversation.
        #expect(rows(sidebar, .agents) == ["agent-old"])
    }

    @Test("a starred duplicate survives the one with newer activity")
    func starredDuplicateWins() {
        let sidebar = build(
            [dm("dm-starred", lastMessageAt: 100), dm("dm-busy", lastMessageAt: 900)],
            entities: people,
            rosters: ["dm-starred": [me, peer], "dm-busy": [me, peer]],
            starred: ["dm-starred"]
        )

        // The star is the one thing here the reader said about a *specific* conversation,
        // so collapsing it away would empty a heading they filled by hand.
        #expect(rows(sidebar, .starred) == ["dm-starred"])
        #expect(rows(sidebar, .directMessages) == [])
    }

    @Test("two people who share a name are two people")
    func distinctPeersAreNeverCollapsed() {
        let sidebar = build(
            [dm("dm-peer", lastMessageAt: 100), dm("dm-twin", lastMessageAt: 200)],
            entities: people + [DirectoryEntity(pubkey: twin, profileName: "Ada")],
            rosters: ["dm-peer": [me, peer], "dm-twin": [me, twin]]
        )

        // Identical titles, different keys. The collapse is keyed on the peer and never on
        // the string, so this stays two rows: the "duplicate" it would tidy away is a real
        // distinction the reader has to keep.
        #expect(rows(sidebar, .directMessages) == ["dm-twin", "dm-peer"])
    }

    @Test("only one-to-one conversations collapse — groups and channels never do")
    func groupsAndChannelsAreNeverCollapsed() {
        let sidebar = build(
            [
                dm("group-a", lastMessageAt: 100),
                dm("group-b", lastMessageAt: 200),
                row("room-a", name: "General", lastMessageAt: 300),
                row("room-b", name: "General", lastMessageAt: 400),
            ],
            entities: people,
            rosters: [
                "group-a": [me, peer, other],
                "group-b": [me, peer, other],
                "room-a": [me, peer, other],
                "room-b": [me, peer, other],
            ]
        )

        // A group is titled by everyone in it, so two of them are at least *readable* as
        // duplicates; and two channels sharing a name are two rooms.
        #expect(rows(sidebar, .directMessages) == ["group-b", "group-a"])
        #expect(rows(sidebar, .channels) == ["room-b", "room-a"])
    }

    @Test("two silent duplicates resolve the same way whichever order they arrive in")
    func collapseIsTotalAndStable() {
        let channels = [dm("dm-a"), dm("dm-b")]
        let rosters = ["dm-a": Set([me, peer]), "dm-b": Set([me, peer])]

        // Neither has activity and the titles are one person's, so only the id tie-break
        // inside `precedes` can decide — which is what keeps the survivor from swapping
        // under a reader as the store re-orders its rows.
        #expect(rows(build(channels, entities: people, rosters: rosters), .directMessages)
            == ["dm-a"])
        #expect(rows(build(channels.reversed(), entities: people, rosters: rosters), .directMessages)
            == ["dm-a"])
    }
}
