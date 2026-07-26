@testable import BuzzKit
import NostrCore
import Testing

@Suite("Composer mention candidates", .timeLimit(.minutes(1)))
struct MentionCandidatesTests {
    @Test("returns channel members and only eligible non-member relay agents")
    func memberAndAgentEligibility() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let me = try Fixture()
        let member = try Fixture()
        let shared = try Fixture()
        let allowed = try Fixture()
        let hidden = try Fixture()

        _ = try await store.ingest(batch: [
            try relay.event(
                .groupMetadata,
                #"{"name":"room"}"#,
                tags: [["d", "room-1"]],
                at: 1_000
            ),
            try relay.event(
                .groupMembers,
                "",
                tags: [["d", "room-1"], ["p", member.pubkey]],
                at: 1_001
            ),
            try member.event(.metadata, #"{"display_name":"Member"}"#, at: 900),
            try shared.event(
                .agentProfile,
                #"{"display_name":"Shared Agent","respond_to":"anyone","channel_ids":["room-1"]}"#,
                at: 1_002
            ),
            try allowed.event(
                .agentProfile,
                """
                {"display_name":"Allowed Agent","respond_to":"allowlist",\
                "respond_to_allowlist":["\(me.pubkey.uppercased())"],"channel_ids":[]}
                """,
                at: 1_003
            ),
            try hidden.event(
                .agentProfile,
                #"{"display_name":"Hidden Agent","respond_to":"owner-only","channel_ids":["room-1"]}"#,
                at: 1_004
            ),
        ], phase: .backfill)

        let candidates = try store.mentionCandidates(channel: "room-1", selfPubkey: me.pubkey)
        #expect(candidates.map(\.displayName) == ["Member", "Allowed Agent", "Shared Agent"])
        #expect(candidates[0].isChannelMember)
        #expect(!candidates[0].isAgent)
        #expect(candidates.dropFirst().allSatisfy { $0.isAgent })
        #expect(!candidates.contains { $0.pubkey == hidden.pubkey })
    }

    @Test("newest agent profile wins and rebuild reproduces it")
    func newestAgentProfileWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open(projectionVersion: 1)
        let agent = try Fixture()

        _ = try await store.ingest(batch: [
            try agent.event(
                .agentProfile,
                #"{"display_name":"New","respond_to":"anyone","channel_ids":["room-1"]}"#,
                at: 2_000
            ),
            try agent.event(
                .agentProfile,
                #"{"display_name":"Old","respond_to":"owner-only","channel_ids":[]}"#,
                at: 1_000
            ),
        ], phase: .live)
        let live = try await store.projectionSnapshot()

        let rebuilt = try await database.open(projectionVersion: 2).projectionSnapshot()
        #expect(rebuilt == live)
        #expect(live["agent_directory"]?.first?.contains("New") == true)
    }
}
