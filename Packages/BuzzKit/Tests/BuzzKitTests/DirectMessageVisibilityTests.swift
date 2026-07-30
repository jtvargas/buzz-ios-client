@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// Hiding a direct message (NIP-DV).
///
/// The defect these cover: a hide is *presentation*, not membership, so the DM's
/// kind-39002 roster still names you and a client that rebuilds its list from
/// membership alone has no way to know. The relay states the hide in a second,
/// relay-signed event addressed to you — kind 30622, one `h` tag per hidden DM —
/// and nothing else on the wire carries it.
@Suite("Hidden direct messages")
struct DirectMessageVisibilityTests {
    /// Builds the three responses one `fetch` consumes, in the order it asks for
    /// them: the visibility snapshot, the membership page, then the per-channel
    /// state batch.
    private struct Relay {
        let relay: Fixture
        let identity: Fixture

        init() throws {
            relay = try Fixture()
            identity = try Fixture()
        }

        func metadata(_ channel: String, name: String, archived: Bool = false) throws -> NostrEvent {
            var tags = [["d", channel]]
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

        /// A relay-signed visibility snapshot for `viewer`, hiding `channels`.
        func visibility(
            viewer: String,
            hiding channels: [String],
            at seconds: Int64 = 20
        ) throws -> NostrEvent {
            try relay.event(
                .dmVisibility,
                "",
                tags: [["d", viewer], ["p", viewer]] + channels.map { ["h", $0] },
                at: seconds
            )
        }
    }

    private static func json(_ events: [NostrEvent]) throws -> Data {
        try JSONEncoder().encode(events)
    }

    private static func client(_ transport: FakeHTTPTransport, signer: InMemorySigner) -> ChannelDirectoryClient {
        ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer
        )
    }

    // MARK: - The read

    @Test("a hidden DM is demoted out of the sidebar while the roster still names you")
    func hiddenDirectMessageLeavesTheActiveSet() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let rosters = [
            try fixture.roster("dm-hidden", members: [identity, "peer"]),
            try fixture.roster("room", members: [identity]),
        ]
        let metadata = [
            try fixture.metadata("dm-hidden", name: "Peer"),
            try fixture.metadata("room", name: "Room"),
        ]

        await transport.enqueue(
            status: 200,
            body: try Self.json([fixture.visibility(viewer: identity, hiding: ["dm-hidden"])])
        )
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )

        #expect(snapshot.states["dm-hidden"] == .hidden)
        #expect(snapshot.states["room"] == .active)
        // The snapshot is read, never ingested: it is relay-signed state with no
        // projection, and admitting it would put an unprojectable row in the log.
        #expect(snapshot.events.allSatisfy { $0.kind != EventKind.dmVisibility })
    }

    @Test("the visibility query names kind 30622 and #p = self, and takes the newest snapshot")
    func visibilityQueryShapeAndNewestWins() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        // Two snapshots in one answer. Only the newer one is the current hidden set:
        // the older one hid a DM that has since been re-opened.
        let older = try fixture.visibility(viewer: identity, hiding: ["dm-a", "dm-b"], at: 20)
        let newer = try fixture.visibility(viewer: identity, hiding: ["dm-b"], at: 21)
        let rosters = [
            try fixture.roster("dm-a", members: [identity, "peer-a"]),
            try fixture.roster("dm-b", members: [identity, "peer-b"]),
        ]
        let metadata = [
            try fixture.metadata("dm-a", name: "A"),
            try fixture.metadata("dm-b", name: "B"),
        ]

        await transport.enqueue(status: 200, body: try Self.json([older, newer]))
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states["dm-a"] == .active)
        #expect(snapshot.states["dm-b"] == .hidden)

        let requests = await transport.requests
        let filters = try #require(
            try JSONSerialization.jsonObject(with: requests[0].body) as? [[String: Any]]
        )
        #expect(filters[0]["kinds"] as? [Int] == [EventKind.dmVisibility.rawValue])
        // `#p`, not `#d`: `p` is the tag the relay's read gate checks, and it refuses
        // the query outright without it.
        #expect(filters[0]["#p"] as? [String] == [identity])
        #expect(filters[0]["limit"] as? Int == 1)
    }

    @Test("a snapshot addressed to somebody else hides nothing")
    func foreignSnapshotIsIgnored() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let rosters = [try fixture.roster("dm", members: [identity, "peer"])]
        let metadata = [try fixture.metadata("dm", name: "Peer")]
        let stranger = try fixture.visibility(viewer: String(repeating: "f", count: 64), hiding: ["dm"])

        await transport.enqueue(status: 200, body: try Self.json([stranger]))
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states["dm"] == .active)
    }

    @Test("hidden never masks a stronger loss of access")
    func hiddenDoesNotOverrideArchivedOrRemoved() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let rosters = [
            try fixture.roster("dm-archived", members: [identity, "peer"]),
            try fixture.roster("dm-removed", members: ["peer"]),
        ]
        let metadata = [
            try fixture.metadata("dm-archived", name: "Archived", archived: true),
            try fixture.metadata("dm-removed", name: "Removed"),
        ]

        await transport.enqueue(
            status: 200,
            body: try Self.json([
                fixture.visibility(viewer: identity, hiding: ["dm-archived", "dm-removed"]),
            ])
        )
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        // `dm-removed` reaches this pass only because it was active in the last good
        // snapshot — the roster no longer names you, so the membership query does not
        // return it. That is the whole reason the previous set is carried forward.
        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: ["dm-removed"]
        )
        #expect(snapshot.states["dm-archived"] == .archived)
        #expect(snapshot.states["dm-removed"] == .notMember)
    }

    // MARK: - Failure

    @Test("a relay that refuses the visibility query still gets to answer the directory")
    func refusedVisibilityQueryCannotCostTheDirectory() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let rosters = [try fixture.roster("room", members: [identity])]
        let metadata = [try fixture.metadata("room", name: "Room")]

        // 403 is what this relay answers a `#p`-gated kind it will not serve; a relay
        // that has never heard of NIP-DV answers some other non-2xx. Neither may take
        // the sidebar down — the fallback the spec defines is "nothing is hidden".
        await transport.enqueue(status: 403, body: "restricted")
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states["room"] == .active)
    }

    @Test("an unreadable visibility answer is treated as no snapshot, not as a failure")
    func unreadableVisibilityAnswerIsTreatedAsEmpty() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let rosters = [try fixture.roster("room", members: [identity])]
        let metadata = [try fixture.metadata("room", name: "Room")]

        await transport.enqueue(status: 200, body: "not json")
        await transport.enqueue(status: 200, body: try Self.json(rosters))
        await transport.enqueue(status: 200, body: try Self.json(rosters + metadata))

        let snapshot = try await Self.client(transport, signer: signer).fetch(
            selfPubkey: identity,
            previouslyActiveChannels: []
        )
        #expect(snapshot.states["room"] == .active)
    }

    @Test("a visibility query that never reaches the relay fails the whole pass")
    func unreachableRelayFailsThePassRatherThanUnhiding() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let transport = FakeHTTPTransport()

        // The distinction that matters: an answer of "no" is absorbed above, but *no
        // answer* propagates. The caller's response to a thrown fetch is to keep its
        // last committed access rows — which still have the hidden DMs hidden. Absorbing
        // this one instead would flash every hidden DM back onto the sidebar on any
        // network blip.
        await transport.enqueueFailure(.requestFailed("offline"))

        await #expect(throws: ChannelDirectoryError.transport(.requestFailed("offline"))) {
            try await Self.client(transport, signer: signer).fetch(
                selfPubkey: fixture.identity.pubkey,
                previouslyActiveChannels: []
            )
        }
    }

    // MARK: - The store

    @Test("a hidden DM leaves the sidebar, keeps its history, and stays writable")
    func hiddenDirectMessageKeepsHistoryAndRemainsWritable() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Relay()
        let identity = fixture.identity.pubkey

        let metadata = try fixture.metadata("dm", name: "Peer")
        let roster = try fixture.roster("dm", members: [identity, "peer"])
        let message = try fixture.identity.message("still here", in: "dm", at: 12)
        try await store.ingest(batch: [metadata, roster, message], phase: .backfill)

        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata, roster], states: ["dm": .hidden]),
            identity: identity
        )

        #expect(try store.channelList(selfPubkey: identity).isEmpty)
        #expect(try store.channelAccessState(identity: identity, channel: "dm") == .hidden)
        // Hiding is a sidebar choice, not a lock: the relay still delivers here and
        // still accepts what you write, so the conversation must not go read-only.
        #expect(ChannelAccessState.hidden.isWritable)
        #expect(try store.timeline(channel: "dm", limit: 10).count == 1)
    }

    @Test("a hidden DM is re-checked by the next pass, so un-hiding restores it")
    func unhidingRestoresTheDirectMessage() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Relay()
        let identity = fixture.identity.pubkey

        let metadata = try fixture.metadata("dm", name: "Peer")
        let roster = try fixture.roster("dm", members: [identity, "peer"])
        try await store.ingest(batch: [metadata, roster], phase: .backfill)
        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata, roster], states: ["dm": .hidden]),
            identity: identity
        )

        // A hidden row has to stay in the set the next pass re-checks. Membership never
        // changed, so the roster query would find it anyway — but a hidden DM whose
        // membership *does* later change must still be able to reach `.notMember`
        // rather than sit hidden forever.
        #expect(try await store.previouslyActiveChannelIDs(identity: identity) == ["dm"])

        try await store.applyChannelDirectorySnapshot(
            ChannelDirectorySnapshot(events: [metadata, roster], states: ["dm": .active]),
            identity: identity
        )
        #expect(try store.channelList(selfPubkey: identity).map(\.id) == ["dm"])
    }
}
