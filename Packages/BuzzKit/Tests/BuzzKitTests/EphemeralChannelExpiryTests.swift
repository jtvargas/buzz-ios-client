@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// An ephemeral channel that has outlived its deadline stops being discoverable.
///
/// The defect these cover, reported as *"weird channels named `livesub-*` and
/// `buzzkit-*` started appearing"*: a Buzz relay stamps `ttl_seconds` and a
/// `ttl_deadline` on an ephemeral channel and publishes both on its kind-39000
/// (`buzz-relay/src/handlers/side_effects.rs:1101-1107`), and is supposed to archive the
/// row itself once that deadline passes (`buzz-db/src/channel.rs:1495`). When it has not,
/// a channel asked to live five minutes stays open, answerable and discoverable
/// indefinitely, and open-channel discovery shows it to everybody on that relay.
///
/// The eight on `homelab.tail4bc643.ts.net` were made by this package's own live suite
/// (`LivePiSupport.swift:165`, `ttlSeconds: 300`), owned by throwaway keys, eleven days
/// past a five-minute deadline and still unarchived — created one day before that relay's
/// reaper existed.
@Suite("Ephemeral channel expiry")
struct EphemeralChannelExpiryTests {
    private struct Relay {
        let relay: Fixture
        let identity: Fixture

        init() throws {
            relay = try Fixture()
            identity = try Fixture()
        }

        /// Channel metadata as the relay signs it, optionally carrying the deadline it
        /// publishes for an ephemeral channel.
        func metadata(
            _ channel: String,
            name: String,
            open: Bool,
            deadline: String? = nil
        ) throws -> NostrEvent {
            var tags = [["d", channel], ["closed"]]
            tags.append(open ? ["public"] : ["private"])
            if let deadline {
                tags.append(["ttl", "300"])
                tags.append(["ttl_deadline", deadline])
            }
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

    private static let asOf = Date(timeIntervalSince1970: 1_785_600_000)

    // MARK: - The rule itself

    @Test("a deadline in the past is out of time, and one in the future is not")
    func aDeadlineIsReadAgainstTheClock() throws {
        let fixture = try Relay()
        let expired = try fixture.metadata(
            "livesub-3cc7ab2e",
            name: "livesub-3cc7ab2e",
            open: true,
            deadline: "2026-07-22T12:00:00+00:00"
        )
        let live = try fixture.metadata(
            "standup",
            name: "standup",
            open: true,
            deadline: "2026-08-30T12:00:00+00:00"
        )

        #expect(ChannelDirectoryClient.hasOutlivedItsDeadline(expired, now: Self.asOf))
        #expect(!ChannelDirectoryClient.hasOutlivedItsDeadline(live, now: Self.asOf))
    }

    /// The relay writes these with `chrono`'s `to_rfc3339`, which carries fractional
    /// seconds. A parser that only understood whole seconds would read every real deadline
    /// as unparseable and therefore as *not* expired — which is this fix doing nothing at
    /// all, silently.
    @Test("the deadline parses with or without fractional seconds")
    func bothShapesOfTheRelaysTimestampAreRead() throws {
        let fixture = try Relay()
        for stamp in ["2026-07-22T12:00:00.123456+00:00", "2026-07-22T12:00:00+00:00", "2026-07-22T12:00:00Z"] {
            let event = try fixture.metadata("c", name: "c", open: true, deadline: stamp)
            #expect(
                ChannelDirectoryClient.hasOutlivedItsDeadline(event, now: Self.asOf),
                "did not read \(stamp) as a deadline"
            )
        }
    }

    /// Absent or unreadable is *not* expired. An ordinary channel has no deadline at all,
    /// and a timestamp this client cannot parse is not grounds for hiding a conversation.
    @Test("no deadline, or one that cannot be read, leaves a channel alone")
    func anUnreadableDeadlineNeverHidesAChannel() throws {
        let fixture = try Relay()
        let ordinary = try fixture.metadata("general", name: "general", open: true)
        let nonsense = try fixture.metadata("odd", name: "odd", open: true, deadline: "soon")

        #expect(!ChannelDirectoryClient.hasOutlivedItsDeadline(ordinary, now: Self.asOf))
        #expect(!ChannelDirectoryClient.hasOutlivedItsDeadline(nonsense, now: Self.asOf))
    }

    // MARK: - What the sidebar is handed

    @Test("an expired open channel is not discovered, and a live one still is")
    func expiredChannelsAreLeftOutOfDiscovery() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let discovered = [
            try fixture.metadata("general", name: "general", open: true),
            try fixture.metadata(
                "livesub-3cc7ab2e",
                name: "livesub-3cc7ab2e",
                open: true,
                deadline: "2026-07-22T12:00:00+00:00"
            ),
        ]
        // Neither roster names this key: both are reachable only through discovery, which
        // is exactly the position JT's phone was in.
        let rosters = [
            try fixture.roster("general", members: ["someone-else"]),
            try fixture.roster("livesub-3cc7ab2e", members: ["someone-else"]),
        ]

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json(discovered))
        await transport.enqueue(status: 200, body: try Self.json(discovered + rosters))

        let client = ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer,
            now: { Self.asOf }
        )
        let snapshot = try await client.fetch(selfPubkey: identity, previouslyActiveChannels: [])

        #expect(snapshot.states["general"] == .active)
        #expect(snapshot.states["livesub-3cc7ab2e"] == nil)

        // And it was left out *before* the state request, not filtered from the answer:
        // asking about it would spend a batch slot on a channel nobody will be shown.
        let requests = await transport.requests
        let state = try #require(
            try JSONSerialization.jsonObject(with: requests[3].body) as? [[String: Any]]
        )
        let asked = state[0]["#d"] as? [String] ?? []
        #expect(asked.contains("general"))
        #expect(!asked.contains("livesub-3cc7ab2e"))
    }

    /// A channel the viewer actually belongs to is theirs to leave. Expiry removes a
    /// channel from *discovery* — the route by which somebody who never joined is shown
    /// one — and does not reach into a roster the relay says names them.
    @Test("a channel the viewer is a member of survives its own deadline")
    func membershipOutranksTheDeadline() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let expired = try fixture.metadata(
            "standup",
            name: "standup",
            open: true,
            deadline: "2026-07-22T12:00:00+00:00"
        )
        let roster = try fixture.roster("standup", members: [identity])

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json([roster]))
        await transport.enqueue(status: 200, body: try Self.json([expired]))
        await transport.enqueue(status: 200, body: try Self.json([expired, roster]))

        let client = ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer,
            now: { Self.asOf }
        )
        let snapshot = try await client.fetch(selfPubkey: identity, previouslyActiveChannels: [])

        #expect(snapshot.states["standup"] == .active)
    }

    /// The one JT was still looking at.
    ///
    /// Keeping an expired channel out of *discovery* only ever helps a phone that has
    /// never seen it. Every device that ran a build from before that rule already wrote
    /// `channel_access.state = 'active'` for these eight, and an active row is fed back
    /// into the next pass as `previouslyActiveChannels`
    /// (``BuzzEventStore/previouslyActiveChannelIDs(identity:)``) — deliberately, so a
    /// channel whose metadata has since vanished can still reach `.notMember` rather than
    /// sit active for ever. That union re-admits the expired channel behind discovery's
    /// back, `accessStates` reads it as open, calls it `.active` again, and writes it
    /// straight back. The sidebar shows exactly the rows where `state = 'active'`
    /// (`ChannelList.swift:335-338`), so the debris is self-renewing and no amount of
    /// relaunching clears it.
    @Test("an expired channel already cached as active is not renewed")
    func aCachedExpiredChannelLosesItsActiveRow() async throws {
        let fixture = try Relay()
        let signer = InMemorySigner(fixture.identity.key)
        let identity = fixture.identity.pubkey
        let transport = FakeHTTPTransport()

        let expired = try fixture.metadata(
            "livesub-3cc7ab2e",
            name: "livesub-3cc7ab2e",
            open: true,
            deadline: "2026-07-22T12:00:00+00:00"
        )
        // One member, a throwaway key that is not the viewer — the roster
        // `buzz channels members` returns for the real channel on homelab.
        let roster = try fixture.roster("livesub-3cc7ab2e", members: ["someone-else"])

        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: "[]")
        await transport.enqueue(status: 200, body: try Self.json([expired]))
        await transport.enqueue(status: 200, body: try Self.json([expired, roster]))

        let client = ChannelDirectoryClient(
            transport: transport,
            queryURL: URL(string: "https://relay.example.com/query")!,
            signer: signer,
            now: { Self.asOf }
        )
        // The phone's position: the row is already there, cached active by an older build.
        let snapshot = try await client.fetch(
            selfPubkey: identity,
            previouslyActiveChannels: ["livesub-3cc7ab2e"]
        )

        // It has to be *said*, not merely omitted. Omitting it leaves the stale row
        // untouched — ``BuzzEventStore/applyChannelDirectorySnapshot(_:identity:generation:)``
        // only writes the ids the snapshot names — so the sidebar would keep showing it.
        #expect(snapshot.states["livesub-3cc7ab2e"] == .notMember)
    }
}
