@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// The Phase-5 §4 contract: one name-resolution chain, no raw keys or group ids in
/// the UI, and one derivation of "this conversation is a DM".
@Suite("Entity name resolution", .timeLimit(.minutes(1)))
struct EntityNamesTests {
    /// A valid 32-byte key, so the short form exercises the real bech32 path rather
    /// than the malformed-hex fallback.
    private static func key(_ byte: UInt8) -> String {
        String(repeating: String(format: "%02x", byte), count: 32)
    }

    private let me = key(0x11)
    private let peer = key(0x22)
    private let agent = key(0x33)
    private let nameless = key(0x44)

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
        type: String? = nil
    ) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: isPrivate,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil,
            channelType: type
        )
    }

    @Test("falls back profile name, then agent name, then NIP-05 username, then a short npub")
    func fallbackOrder() {
        let resolver = names(entities: [
            DirectoryEntity(pubkey: me, profileName: "Ada", agentName: "ada-bot", nip05: "ada@buzz.dev"),
            DirectoryEntity(pubkey: peer, agentName: "Bumble", nip05: "bumble@buzz.dev", isAgent: true),
            DirectoryEntity(pubkey: agent, nip05: "jarvis@buzz.dev"),
            DirectoryEntity(pubkey: nameless),
        ])

        #expect(resolver.name(for: me) == "Ada")
        #expect(resolver.name(for: peer) == "Bumble")
        #expect(resolver.name(for: agent) == "jarvis")

        // Nothing human known: a short npub, never the 64-character hex key.
        let short = resolver.name(for: nameless)
        #expect(short.hasPrefix("npub1"))
        #expect(short.contains("…"))
        #expect(short.count < 20)
        #expect(!short.contains(nameless))
        #expect(resolver.humanName(for: nameless) == nil)
    }

    @Test("resolves a NIP-05 username, including the root form")
    func nip05Usernames() {
        #expect(EntityNames.username(fromNIP05: "ada@buzz.dev") == "ada")
        #expect(EntityNames.username(fromNIP05: "_@buzz.dev") == "buzz.dev")
        #expect(EntityNames.username(fromNIP05: "@buzz.dev") == "buzz.dev")
        #expect(EntityNames.username(fromNIP05: "  ") == nil)
    }

    @Test("an unknown identity still resolves to a short identifier")
    func unknownIdentity() {
        let resolver = names(entities: [])
        let label = resolver.name(for: peer)
        #expect(label.hasPrefix("npub1"))
        #expect(resolver.entity(for: peer) == nil)
        // Malformed hex degrades rather than rendering whole.
        #expect(resolver.name(for: "not-a-key") == "not-a-ke")
    }

    @Test("takes up to two initials from a name and a question mark from nothing")
    func initials() {
        #expect(EntityNames.initials(from: "Ada Lovelace") == "AL")
        #expect(EntityNames.initials(from: "jarvis") == "J")
        #expect(EntityNames.initials(from: "pi-runner") == "PR")
        #expect(EntityNames.initials(from: "42") == "4")
        #expect(EntityNames.initials(from: nil) == "?")
        #expect(EntityNames.initials(from: "") == "?")
    }

    @Test("a two-member roster containing the local identity is a direct message")
    func directMessageDerivation() {
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: peer, profileName: "Peer", picture: "https://p.example/a.png"),
            ],
            rosters: ["dm-1": [me, peer]],
            channels: [channel("dm-1", name: "dm")],
            selfPubkey: me.uppercased()
        )

        let conversation = resolver.conversation(for: "dm-1")
        #expect(conversation.kind == .direct)
        #expect(conversation.isDirect)
        // The peer's name wins over the channel's own name — a DM is titled by who
        // you are talking to.
        #expect(conversation.title == "Peer")
        #expect(conversation.peer == peer)
        #expect(conversation.picture?.absoluteString == "https://p.example/a.png")
        #expect(conversation.initials == "P")
        #expect(conversation.avatarSeed == peer)
        #expect(resolver.directPeer(in: "dm-1") == peer)
    }

    @Test("a two-member roster whose peer is an agent classifies as an agent conversation")
    func agentDirectMessage() {
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            ],
            rosters: ["dm-2": [me, agent]],
            channels: [channel("dm-2")],
            selfPubkey: me
        )

        let conversation = resolver.conversation(for: "dm-2")
        #expect(conversation.kind == .agent)
        #expect(conversation.isDirect)
        #expect(conversation.title == "Jarvis")
    }

    @Test("three members, a roster without the local identity, or no identity all read as channels")
    func channelDerivation() {
        let entities = [
            DirectoryEntity(pubkey: me, profileName: "Me"),
            DirectoryEntity(pubkey: peer, profileName: "Peer"),
            DirectoryEntity(pubkey: agent, profileName: "Third"),
        ]
        let rosters = [
            "room-1": Set([me, peer, agent]),
            "room-2": Set([peer, agent]),
        ]
        let rows = [channel("room-1", name: "general"), channel("room-2", name: "elsewhere")]

        // `room-1` is three people and no relay type, which is the case the group-DM rule
        // must not swallow: a private channel of three looks exactly like a group DM from
        // here, and only the relay's own word tells them apart.
        let resolver = names(entities: entities, rosters: rosters, channels: rows, selfPubkey: me)
        #expect(resolver.conversation(for: "room-1").kind == .channel)
        #expect(resolver.conversation(for: "room-1").title == "general")
        #expect(resolver.conversation(for: "room-2").kind == .channel)
        #expect(resolver.directPeer(in: "room-2") == nil)

        // A keyless session cannot know whose side of a pair it is on, so every
        // conversation reads as a channel rather than guessing.
        let keyless = names(entities: entities, rosters: ["dm-1": [me, peer]], channels: rows)
        #expect(keyless.conversation(for: "dm-1").kind == .channel)
    }

    @Test("an unnamed channel reads as a human string, never any part of its group id")
    func unnamedChannel() {
        let id = "e2fb859e-3b29-408b-ae28-f9cd56c00af5"
        let resolver = names(entities: [], channels: [channel(id)])
        let conversation = resolver.conversation(for: id)
        #expect(conversation.kind == .channel)
        // Eight characters of a group id is still a group id, and this one answer is the
        // sidebar title, the conversation's nav title, the details title, and a thread's
        // subtitle — most visibly for a DM group another client created with no metadata
        // name, which rendered as `#e2fb859e` in all four.
        #expect(conversation.title == "Untitled conversation")
        #expect(!conversation.title.contains("e2fb859e"))
        #expect(resolver.channelName(for: id) == "Untitled conversation")
        // A whitespace-only metadata name is not a name either — it would render blank.
        #expect(names(entities: [], channels: [channel(id, name: "   ")]).channelName(for: id)
            == "Untitled conversation")
        // A channel the resolver has never heard of resolves the same way, rather than
        // echoing back part of the id it was asked about.
        #expect(names(entities: []).channelName(for: id) == "Untitled conversation")
    }

    @Test("a mention gains the directory's own name as a second alias")
    func aliasedMentionRefs() {
        let resolver = names(entities: [
            DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            DirectoryEntity(pubkey: peer, profileName: "Ada"),
        ])

        // BuzzKit resolves a ref's name from the `profile` projection alone and falls back
        // to eight characters of the key. The directory knows the agent's name, so both
        // spellings register and a message's `@`-scan can match whichever was authored.
        let merged = resolver.aliased([
            MentionRef(pubkey: agent, displayName: String(agent.prefix(8))),
            MentionRef(pubkey: peer, displayName: "Ada"),
        ])
        #expect(merged.map(\.displayName) == [String(agent.prefix(8)), "Ada", "Jarvis"])
        // Originals first, so the store's authored `p`-tag order still wins a name
        // collision; an alias that repeats a name already registered is dropped.
        #expect(merged.prefix(2).map(\.pubkey) == [agent, peer])
        #expect(resolver.aliased([]).isEmpty)
    }

    @Test("a profile-less mention resolves only because the surface aliases through the directory")
    func profilelessMentionNeedsTheDirectoryAlias() throws {
        let rows = [channel("general", name: "General")]
        let resolver = names(
            entities: [
                DirectoryEntity(pubkey: me, profileName: "Me"),
                DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            ],
            rosters: ["general": [me, agent, peer]],
            channels: rows,
            selfPubkey: me
        )
        // What the store hands over for an agent with no kind-0 profile: a "name" that is
        // really a key prefix. The message itself was authored as `@Jarvis`.
        let stored = [MentionRef(pubkey: agent, displayName: String(agent.prefix(8)))]

        // Straight from those refs — what every surface used to build from — the authored
        // token matches nothing and renders as plain text.
        let unaliased = MessageMentionResolver(mentions: stored, channels: .empty, selfPubkey: me)
        #expect(unaliased.mention(forName: "Jarvis") == nil)

        // The resolver a timeline row builds goes through ``EntityNames/aliased(_:)``, and
        // that is what makes the authored token resolve.
        let timeline = MessageMentionResolver(
            mentions: resolver.aliased(stored), channels: .empty, selfPubkey: me
        )
        #expect(timeline.mention(forName: "Jarvis")?.pubkey == agent)

        // The sidebar was the second surface this was asserted across; since Part 6 its
        // rows draw no message text, so the timeline row is the only place a mention is
        // rendered and `aliased(_:)` has one caller. The aliasing itself is asserted
        // directly above, in `aliasesAgentAndProfileNames`.
        #expect(SidebarContent.build(channels: rows, names: resolver)
            .sections.first?.rows.first?.title == "General")
    }

    @Test("a just-opened DM names itself from the peer the relay named, until its roster lands")
    func knownPeerNamesAnUnprojectedDirectMessage() {
        let row = channel("dm-new", isPrivate: true)
        let entities = [
            DirectoryEntity(pubkey: me, profileName: "Me"),
            DirectoryEntity(pubkey: peer, profileName: "Ada"),
            DirectoryEntity(pubkey: agent, profileName: "Third"),
        ]
        // No roster: the relay commits a channel's membership *after* it answers the open
        // command, so a read taken the moment the reply lands legitimately has nothing.
        let resolver = names(entities: entities, channels: [row], selfPubkey: me)

        // Without the peer this is the defect — an unnamed channel, so the untitled
        // placeholder stands where the name of the person just messaged belongs.
        #expect(resolver.conversation(for: row).kind == .channel)
        #expect(resolver.conversation(for: row).title == EntityNames.untitledChannel)

        let hinted = resolver.conversation(for: row, knownPeer: peer)
        #expect(hinted.kind == .direct)
        #expect(hinted.title == "Ada")
        #expect(hinted.peer == peer)
        // And the monogram's tint follows the person, so the DM looks the same here as it
        // will once the sidebar has the row.
        #expect(hinted.avatarSeed == peer)

        // A landed roster is an answer, and an answer wins: a hint cannot turn a channel
        // somebody else's membership event describes into a direct message.
        let projected = names(
            entities: entities,
            rosters: ["dm-new": [me, peer, agent]],
            channels: [row],
            selfPubkey: me
        )
        #expect(projected.conversation(for: row, knownPeer: peer).kind == .channel)
        // Nor does the hint survive a keyless session, which has no "other" member.
        #expect(names(entities: entities, channels: [row])
            .conversation(for: row, knownPeer: peer).kind == .channel)
    }

    @Test("secondary labels prefer NIP-05 and name an agent otherwise")
    func secondaryLabels() {
        let resolver = names(entities: [
            DirectoryEntity(pubkey: me, profileName: "Ada", nip05: "ada@buzz.dev"),
            DirectoryEntity(pubkey: agent, agentName: "Jarvis", isAgent: true),
            DirectoryEntity(pubkey: peer, profileName: "Peer"),
        ])
        #expect(resolver.secondaryLabel(for: me) == "ada@buzz.dev")
        #expect(resolver.secondaryLabel(for: agent) == "Agent")
        #expect(resolver.secondaryLabel(for: peer) == nil)
        #expect(resolver.isAgent(agent))
        #expect(!resolver.isAgent(peer))
    }
}
