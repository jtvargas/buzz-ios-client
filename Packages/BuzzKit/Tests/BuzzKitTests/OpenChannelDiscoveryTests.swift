@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Seeing a community's open channels before joining any of them.
///
/// The defect these cover: a directory built only from "whose kind-39002 roster names
/// me?" is empty for somebody who has just redeemed an invite, because redeeming makes
/// you a member of the *community* and of no channel
/// (`buzz-relay/src/api/invites.rs` writes only relay membership). The relay is
/// willing — `get_accessible_channel_ids` is memberships **UNION** every channel with
/// `visibility = 'open'` (`buzz-db/src/channel.rs:746-761`) — so the blank sidebar was
/// the client never asking.
@Suite("Open channel discovery")
struct OpenChannelDiscoveryTests {
    private struct Relay {
        let relay: Fixture
        let identity: Fixture

        init() throws {
            relay = try Fixture()
            identity = try Fixture()
        }

        /// Channel metadata as the relay signs it. `open` mirrors the `public` /
        /// `private` tag it derives from the `visibility` column
        /// (`side_effects.rs:1064-1071`); `closed` rides along on *every* channel,
        /// exactly as the relay does it, so these fixtures also pin that `closed` is
        /// not what decides visibility.
        func metadata(
            _ channel: String,
            name: String,
            open: Bool,
            archived: Bool = false
        ) throws -> NostrEvent {
            var tags = [["d", channel], ["closed"]]
            tags.append(open ? ["public"] : ["private"])
            if archived { tags.append(["archived", "true"]) }
            return try relay.event(.groupMetadata, #"{"name":"\#(name)"}"#, tags: tags, at: 10)
        }

        func roster(_ channel: String, members: [String]) throws -> NostrEvent {
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", channel]] + members.map { ["p", $0] },
                at: 11
            )
        }
    }

    private static func json(_ events: [NostrEvent]) throws -> Data {
        try JSONEncoder().encode(events)
    }

    private static func client(
        _ transport: FakeHTTPTransport,
        signer: InMemorySigner
    ) -> ChannelDirectoryClient {
        ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer
        )
    }

    @Test("a fresh community member sees its open channels without being on any roster")
    func openChannelsArriveForANonMember() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let discovered = [
            try fixture.metadata("welcome-everyone", name: "welcome-everyone", open: true),
            try fixture.metadata("general", name: "general", open: true),
        ]
        // The rosters exist and simply do not name this key — which is the state a relay
        // leaves you in after an invite, and the state that used to read as "no channels".
        let rosters = [
            try fixture.roster("welcome-everyone", members: ["someone-else"]),
            try fixture.roster("general", members: ["someone-else"]),
        ]

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json(discovered))
        await transport.enqueue(status: 200, body: try Self.json(discovered + rosters))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )

        #expect(snapshot.states["welcome-everyone"] == .active)
        #expect(snapshot.states["general"] == .active)

        // The discovery query itself: kind 39000 and **no `#d`**. Naming the channels
        // would defeat the point of asking which ones exist, and restoring a `#d` here
        // is exactly how this regresses to the blank sidebar.
        let requests = await transport.requests
        let discovery = try #require(
            try JSONSerialization.jsonObject(with: requests[2].body) as? [[String: Any]]
        )
        #expect(discovery[0]["kinds"] as? [Int] == [EventKind.groupMetadata.rawValue])
        #expect(discovery[0]["#d"] == nil)
    }

    @Test("discovery does not hand over a private channel the viewer was removed from")
    func privateChannelsStayClosedToANonMember() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        // A relay would not serve this metadata to a non-member at all. Scripting it
        // anyway is the point: the client must not promote a private room to `.active`
        // even when one reaches it, so the rule is the tag and not the relay's goodwill.
        let discovered = [
            try fixture.metadata("open-room", name: "open-room", open: true),
            try fixture.metadata("private-room", name: "private-room", open: false),
        ]
        let rosters = [
            try fixture.roster("open-room", members: ["someone-else"]),
            try fixture.roster("private-room", members: ["someone-else"]),
        ]

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json(discovered))
        await transport.enqueue(status: 200, body: try Self.json(discovered + rosters))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )

        #expect(snapshot.states["open-room"] == .active)
        #expect(snapshot.states["private-room"] == .notMember)
    }

    @Test("an archived open channel stays archived rather than being rediscovered")
    func archivedOpenChannelIsNotResurrected() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let discovered = [
            try fixture.metadata("old-room", name: "old-room", open: true, archived: true),
        ]
        let rosters = [try fixture.roster("old-room", members: ["someone-else"])]

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json(discovered))
        await transport.enqueue(status: 200, body: try Self.json(discovered + rosters))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )

        #expect(snapshot.states["old-room"] == .archived)
    }

    @Test("metadata with no visibility tag is not treated as open")
    func absentVisibilityTagIsNotOpen() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        // A `closed` tag and nothing else — the shape an older relay's metadata has.
        // Reading `closed` as "not open" would be right by accident; reading the
        // *absence* of `public` as open would quietly re-admit every private room.
        let discovered = [
            try fixture.relay.event(
                .groupMetadata,
                #"{"name":"legacy"}"#,
                tags: [["d", "legacy"], ["closed"]],
                at: 10
            ),
        ]
        let rosters = [try fixture.roster("legacy", members: ["someone-else"])]

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json(discovered))
        await transport.enqueue(status: 200, body: try Self.json(discovered + rosters))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )

        #expect(snapshot.states["legacy"] == .notMember)
    }
}
