@testable import BuzzKit
import NostrCore
import Testing

/// The Phase-5 directory read: every nameable identity and every channel roster in
/// one snapshot, so the UI resolves names and DM peers by lookup instead of by
/// query-per-row.
@Suite("Directory snapshot read API", .timeLimit(.minutes(1)))
struct DirectoryTests {
    @Test("carries raw profile fields, agent flags, and rosters")
    func snapshotShape() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let me = try Fixture()
        let peer = try Fixture()
        let bot = try Fixture()
        let directoryAgent = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, #"{"name":"room"}"#, tags: [["d", "room-1"]], at: 1_000),
            try relay.event(.groupMembers, "", tags: [
                ["d", "room-1"],
                ["p", me.pubkey],
                ["p", peer.pubkey],
                // The relay's real shape: the role rides the petname slot and the relay
                // hint before it is empty. See `BuzzProjector.projectRoster`.
                ["p", bot.pubkey, "", "bot"],
            ], at: 1_001),
            try relay.event(.groupMetadata, #"{"name":"dm"}"#, tags: [["d", "dm-1"]], at: 1_002),
            try relay.event(.groupMembers, "", tags: [
                ["d", "dm-1"],
                ["p", me.pubkey],
                ["p", peer.pubkey],
            ], at: 1_003),
            try peer.event(
                .metadata,
                #"{"display_name":"Peer","picture":"p.png","nip05":"peer@buzz"}"#,
                at: 900
            ),
            try directoryAgent.event(
                .agentProfile,
                #"{"display_name":"Bumble","respond_to":"anyone","channel_ids":["room-1"]}"#,
                at: 1_004
            ),
        ], phase: .backfill)

        let snapshot = try store.directorySnapshot()

        // Rosters come back per channel, lowercased, so a two-member roster is a
        // recognisable DM.
        #expect(snapshot.members(of: "room-1").count == 3)
        #expect(snapshot.members(of: "dm-1") == [me.pubkey.lowercased(), peer.pubkey.lowercased()])
        #expect(snapshot.members(of: "unknown").isEmpty)

        // A profile's fields arrive raw — no key-prefix fallback baked in.
        let peerEntity = snapshot.entity(peer.pubkey.uppercased())
        #expect(peerEntity?.profileName == "Peer")
        #expect(peerEntity?.picture == "p.png")
        #expect(peerEntity?.nip05 == "peer@buzz")
        #expect(peerEntity?.isAgent == false)

        // A roster member with no kind-0 is still present, merely unnamed.
        let meEntity = snapshot.entity(me.pubkey)
        #expect(meEntity != nil)
        #expect(meEntity?.profileName == nil)

        // Agent identity comes from either authority: a roster `bot` role...
        #expect(snapshot.entity(bot.pubkey)?.isAgent == true)
        // ...or the relay's agent directory, which also carries its own name.
        let agentEntity = snapshot.entity(directoryAgent.pubkey)
        #expect(agentEntity?.isAgent == true)
        #expect(agentEntity?.agentName == "Bumble")
        #expect(agentEntity?.profileName == nil)
    }

    @Test("prefers a profile name over the agent directory name and drops blank names")
    func namesAndBlanks() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let agent = try Fixture()
        let blank = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMembers, "", tags: [
                ["d", "room-1"],
                ["p", agent.pubkey],
                ["p", blank.pubkey],
            ], at: 1_000),
            try agent.event(.metadata, #"{"display_name":"Jarvis"}"#, at: 900),
            try agent.event(
                .agentProfile,
                #"{"display_name":"jarvis-agent","respond_to":"anyone","channel_ids":["room-1"]}"#,
                at: 1_001
            ),
            try blank.event(.metadata, #"{"display_name":"   ","picture":""}"#, at: 900),
        ], phase: .backfill)

        let snapshot = try store.directorySnapshot()

        // Both names survive separately; which one wins is the UI's fallback call.
        let agentEntity = snapshot.entity(agent.pubkey)
        #expect(agentEntity?.profileName == "Jarvis")
        #expect(agentEntity?.agentName == "jarvis-agent")

        // Whitespace-only and empty fields normalise to nil rather than rendering as
        // a blank name or a broken image.
        let blankEntity = snapshot.entity(blank.pubkey)
        #expect(blankEntity != nil)
        #expect(blankEntity?.profileName == nil)
        #expect(blankEntity?.picture == nil)
    }

    /// The regression this suite could not previously fail.
    ///
    /// Both roster shapes have to name an agent, and neither may leave `role` as the
    /// empty string: `Directory` tests it with `== "bot"` and the Activity feed with
    /// `LOWER(cm.role) = 'bot'`, so `""` reads as "this is a person" everywhere at
    /// once. Only the four-element form appears on the live relay — 5,078 of 5,078
    /// member tags — and it is the one the old reader got wrong.
    @Test("takes the roster role from the petname slot, and from the relay slot when that is all there is")
    func rosterRoleFromEitherTagShape() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let wireBot = try Fixture()
        let shortBot = try Fixture()
        let person = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(.groupMetadata, #"{"name":"room"}"#, tags: [["d", "room-1"]], at: 1_000),
            try relay.event(.groupMembers, "", tags: [
                ["d", "room-1"],
                // What the relay signs.
                ["p", wireBot.pubkey, "", "bot"],
                // The short form kind 39001 uses, tolerated rather than required.
                ["p", shortBot.pubkey, "bot"],
                ["p", person.pubkey, "", "member"],
            ], at: 1_001),
        ], phase: .backfill)

        let snapshot = try store.directorySnapshot()
        #expect(snapshot.entity(wireBot.pubkey)?.isAgent == true)
        #expect(snapshot.entity(shortBot.pubkey)?.isAgent == true)
        #expect(snapshot.entity(person.pubkey)?.isAgent == false)
    }

    @Test("an empty store yields an empty snapshot")
    func emptyStore() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()

        let snapshot = try store.directorySnapshot()
        #expect(snapshot.entities.isEmpty)
        #expect(snapshot.memberPubkeysByChannel.isEmpty)
        #expect(snapshot == .empty)
    }
}
