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
        isPrivate: Bool = false
    ) -> ChannelListRow {
        ChannelListRow(
            id: id,
            name: name,
            about: nil,
            picture: nil,
            isPrivate: isPrivate,
            lastMessageAt: nil,
            lastMessageSnippet: nil,
            lastMessageAuthor: nil
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

    @Test("an unnamed channel shows a short id, never its whole group id")
    func unnamedChannel() {
        let id = "e2fb859e-3b29-408b-ae28-f9cd56c00af5"
        let resolver = names(entities: [], channels: [channel(id)])
        let conversation = resolver.conversation(for: id)
        #expect(conversation.kind == .channel)
        #expect(conversation.title == "e2fb859e")
        #expect(!conversation.title.contains(id))
        #expect(resolver.channelName(for: id) == "e2fb859e")
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
