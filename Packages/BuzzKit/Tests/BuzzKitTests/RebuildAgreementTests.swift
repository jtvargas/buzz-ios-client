@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Rebuild agreement (spec T6): a mixed history — edits, deletions including
/// unauthorized ones, replaceables delivered out of order, an owner-attested agent
/// message — must land byte-identical projections whether it is ingested live or
/// replayed by a version-bump rebuild. The rebuild replays the log oldest-first,
/// so agreement is what proves every projection converges regardless of arrival
/// order.
@Suite("Rebuild agreement", .timeLimit(.minutes(1)))
struct RebuildAgreementTests {
    /// A history that touches every projection the store keeps. Replaceables are
    /// deliberately supplied newest-first so an unguarded projection would settle
    /// on the stale version and diverge from the ordered replay.
    private static func mixedHistory(
        author: Fixture,
        agent: Fixture,
        owner: Fixture,
        stranger: Fixture,
        relay: Fixture
    ) throws -> [NostrEvent] {
        let root = try author.message("thread opener", at: 1000)
        let reply = try author.event(
            .channelMessage, "a reply", tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1010
        )
        let broadcast = try author.event(
            .channelMessage, "echoed reply",
            tags: [["h", "room-1"], ["e", root.id, "", "reply"], ["broadcast", "1"]], at: 1020
        )
        let plain = try author.message("plain message", at: 1030)
        let auth = try owner.authTag(authorizing: agent.pubkey)
        let agentMessage = try agent.event(
            .channelMessage, "agent message", tags: [["h", "room-1"], auth], at: 1040
        )

        return [
            root, reply, broadcast, plain, agentMessage,

            // Replaceables, newest-first.
            try relay.event(.groupMetadata, #"{"name":"New"}"#, tags: [["d", "room-1"]], at: 2000),
            try relay.event(.groupMetadata, #"{"name":"Old"}"#, tags: [["d", "room-1"]], at: 900),
            try relay.event(
                .groupAdmins, "", tags: [["d", "room-1"], ["p", owner.pubkey, "owner"]], at: 2000
            ),
            try author.event(.metadata, #"{"display_name":"Newer"}"#, at: 2000),
            try author.event(.metadata, #"{"display_name":"Older"}"#, at: 900),
            try agent.event(
                .agentProfile,
                #"{"display_name":"Agent New","respond_to":"anyone","channel_ids":["room-1"]}"#,
                at: 2000
            ),
            try agent.event(
                .agentProfile,
                #"{"display_name":"Agent Old","respond_to":"owner-only","channel_ids":[]}"#,
                at: 900
            ),
            try relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice", "admin"]], at: 2000),
            try relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "bob"]], at: 900),
            try relay.event(.threadSummary, #"{"n":9}"#, tags: [["d", root.id]], at: 2000),
            try relay.event(.threadSummary, #"{"n":1}"#, tags: [["d", root.id]], at: 900),

            // Rich content, newest-first, collapses to the newest payload.
            try author.event(.richMessage, #"{"v":2}"#, tags: [["e", plain.id]], at: 1200),
            try author.event(.richMessage, #"{"v":1}"#, tags: [["e", plain.id]], at: 1100),

            // Reactions.
            try author.event(.reaction, "🐝", tags: [["e", plain.id]], at: 1050),
            try stranger.event(.reaction, "🔥", tags: [["e", plain.id]], at: 1060),

            // Edits: one by the author (authorized), one by a stranger (recorded but
            // never applied at read time).
            try author.event(.messageEdit, "plain message, edited", tags: [["e", plain.id]], at: 1070),
            try stranger.event(.messageEdit, "vandalized", tags: [["e", plain.id]], at: 1080),
            // An owner edit of the agent's message.
            try owner.event(.messageEdit, "agent message, owner-edited", tags: [["e", agentMessage.id]], at: 1090),

            // Deletions: the author's own, a stranger's (unauthorized), and a relay
            // 9005 tombstone — all recorded regardless of whether they will apply.
            try author.event(.deletion, "", tags: [["e", reply.id]], at: 1100),
            try stranger.event(.deletion, "", tags: [["e", plain.id]], at: 1110),
            try relay.event(.groupDeleteEvent, "", tags: [["e", broadcast.id]], at: 1120),
        ]
    }

    @Test("a version-bump rebuild reproduces the projections of an out-of-order live ingest")
    func rebuildMatchesLive() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let author = try Fixture()
        let agent = try Fixture()
        let owner = try Fixture()
        let stranger = try Fixture()
        let relay = try Fixture()

        let history = try Self.mixedHistory(
            author: author, agent: agent, owner: owner, stranger: stranger, relay: relay
        )

        var live: [String: [String]] = [:]
        do {
            let store = try database.open(projectionVersion: 1)
            _ = try await store.ingest(batch: history, phase: .backfill)
            live = try await store.projectionSnapshot()
            // Sanity: the history actually populated every projection table.
            for (table, rows) in live {
                #expect(!rows.isEmpty, "projection \(table) should not be empty")
            }
        }

        // Reopen at a bumped version: init drops the projections and replays the
        // whole log oldest-first through the same projector.
        let reopened = try database.open(projectionVersion: 2)
        let rebuilt = try await reopened.projectionSnapshot()

        #expect(rebuilt == live)
        #expect(try await reopened.metaValue(Schema.projectionVersionKey) == "2")
    }
}
