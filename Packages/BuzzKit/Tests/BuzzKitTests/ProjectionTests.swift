@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("Projections", .timeLimit(.minutes(1)))
struct ProjectionTests {
    // MARK: - Channel metadata (39000, addressable by d)

    @Test("projects channel metadata keyed by its d tag")
    func projectsChannel() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(
                .groupMetadata,
                #"{"name":"General","about":"the main room"}"#,
                tags: [["d", "room-1"]],
                at: 1000
            ),
        ], phase: .backfill)

        let name = try await store.strings("SELECT name FROM channel WHERE id = 'room-1'", column: "name")
        let about = try await store.strings("SELECT about FROM channel WHERE id = 'room-1'", column: "about")
        #expect(name == ["General"])
        #expect(about == ["the main room"])
    }

    @Test("a staler channel event resent after a newer one does not clobber it")
    func channelStalenessGuard() async throws {
        // A relay can resend an older addressable after a reconnect; the newer one
        // must win however the two arrive.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(.groupMetadata, #"{"name":"New"}"#, tags: [["d", "room-1"]], at: 2000),
            relay.event(.groupMetadata, #"{"name":"Old"}"#, tags: [["d", "room-1"]], at: 1000),
        ], phase: .backfill)

        #expect(try await store.strings("SELECT name FROM channel WHERE id = 'room-1'", column: "name") == ["New"])
    }

    // MARK: - Roster (39002, authoritative full replace)

    @Test("replaces the whole roster rather than merging it")
    func rosterReplaces() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"], ["p", "bob"]], at: 1000),
        ], phase: .backfill)
        #expect(try await members(store) == ["alice", "bob"])

        // A newer roster dropping bob and adding carol: bob must disappear.
        _ = try await store.ingest(batch: [
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"], ["p", "carol"]], at: 2000),
        ], phase: .live)
        #expect(try await members(store) == ["alice", "carol"])
    }

    @Test("a staler roster resent after a newer one does not clobber it")
    func rosterStalenessGuard() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        // Newer roster first, then an older one arrives out of order.
        _ = try await store.ingest(batch: [
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "carol"]], at: 2000),
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"], ["p", "bob"]], at: 1000),
        ], phase: .backfill)

        #expect(try await members(store) == ["carol"])
    }

    // MARK: - Profile (kind 0, replaceable per pubkey)

    @Test("projects a profile and keeps only the newest per pubkey")
    func profileStalenessGuard() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let person = try Fixture()

        _ = try await store.ingest(batch: [
            person.event(.metadata, #"{"display_name":"Newer"}"#, at: 2000),
            person.event(.metadata, #"{"display_name":"Older"}"#, at: 1000),
        ], phase: .backfill)

        #expect(try await store.strings(
            "SELECT display_name FROM profile WHERE pubkey = '\(person.pubkey)'",
            column: "display_name"
        ) == ["Newer"])
    }

    // MARK: - Engagement recorded without judging

    @Test("records a reaction against its target")
    func recordsReaction() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("react to me", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.reaction, "🐝", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try await store.strings("SELECT target_id FROM reaction", column: "target_id") == [message.id])
        #expect(try await store.strings("SELECT emoji FROM reaction", column: "emoji") == ["🐝"])
    }

    @Test("records a deletion whatever key signed it, leaving authority to read time")
    func recordsDeletionUnjudged() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let stranger = try Fixture()
        let message = try author.message("target", at: 1000)

        // A deletion by someone who is not the author is still recorded; whether it
        // applies is decided by the timeline predicate, not here.
        _ = try await store.ingest(batch: [
            message,
            stranger.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try await store.rowCount("deletion") == 1)
        #expect(try await store.strings("SELECT deleted_by FROM deletion", column: "deleted_by") == [stranger.pubkey])
    }

    @Test("records every edit, leaving newest-authorized selection to read time")
    func recordsEdits() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("original", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            fixture.event(.messageEdit, "first edit", tags: [["e", message.id]], at: 1001),
            fixture.event(.messageEdit, "second edit", tags: [["e", message.id]], at: 1002),
        ], phase: .backfill)

        #expect(try await store.rowCount("edit") == 2)
    }

    @Test("collapses rich content to the newest payload per target")
    func richContentLatestWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let message = try fixture.message("target", at: 1000)

        // Newer rich payload first, older second — the newer must survive.
        _ = try await store.ingest(batch: [
            message,
            fixture.event(.richMessage, #"{"v":2}"#, tags: [["e", message.id]], at: 1002),
            fixture.event(.richMessage, #"{"v":1}"#, tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try await store.rowCount("rich_content") == 1)
        #expect(try await store.strings("SELECT payload FROM rich_content", column: "payload") == [#"{"v":2}"#])
    }

    @Test("keeps the newest thread summary per root")
    func threadSummaryLatestWins() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()

        _ = try await store.ingest(batch: [
            relay.event(.threadSummary, #"{"replies":9}"#, tags: [["d", "root-1"]], at: 2000),
            relay.event(.threadSummary, #"{"replies":3}"#, tags: [["d", "root-1"]], at: 1000),
        ], phase: .backfill)

        #expect(try await store.rowCount("thread_summary") == 1)
        #expect(try await store.strings("SELECT payload FROM thread_summary", column: "payload") == [#"{"replies":9}"#])
    }

    // MARK: - Owner attestation

    @Test("records the verified owner of an attested event, and nothing for a forged tag")
    func ownerAttestation() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let owner = try Fixture()
        let agent = try Fixture()
        let stranger = try Fixture()

        let valid = try agent.event(
            .channelMessage, "attested",
            tags: [["h", "room-1"], owner.authTag(authorizing: agent.pubkey)], at: 1000
        )
        // A tag whose owner signature does not verify grants no provenance.
        var forgedTag = try owner.authTag(authorizing: agent.pubkey)
        forgedTag[3] = String(forgedTag[3].dropLast()) + (forgedTag[3].hasSuffix("0") ? "1" : "0")
        let forged = try agent.event(
            .channelMessage, "not attested", tags: [["h", "room-1"], forgedTag], at: 1001
        )
        // A plain human message carries no attestation at all.
        let plain = try stranger.message("plain", at: 1002)

        _ = try await store.ingest(batch: [valid, forged, plain], phase: .backfill)

        #expect(try await store.rowCount("event_owner") == 1)
        #expect(try await store.strings(
            "SELECT owner_pubkey FROM event_owner WHERE event_id = '\(valid.id)'",
            column: "owner_pubkey"
        ) == [owner.pubkey])
    }

    // MARK: - Threading

    @Test("writes a thread row only for real replies")
    func threadRows() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let fixture = try Fixture()
        let root = try fixture.message("root", at: 1000)
        let reply = try fixture.event(
            .channelMessage, "reply", tags: [["h", "room-1"], ["e", root.id, "", "reply"]], at: 1001
        )

        _ = try await store.ingest(batch: [root, reply], phase: .backfill)

        // The opener is not a reply, so only the reply gets a thread row.
        #expect(try await store.strings("SELECT event_id FROM thread", column: "event_id") == [reply.id])
        #expect(try await store.strings("SELECT root_id FROM thread", column: "root_id") == [root.id])
    }

    // MARK: - Out-of-order replay (exit criterion)

    @Test("an older replaceable arriving after a newer one never clobbers it, live or rebuilt")
    func outOfOrderReplaceableReplay() async throws {
        // The exit criterion for staleness: whatever order channel, profile, roster,
        // and thread-summary replaceables arrive in, the newest wins — and a
        // version-bump rebuild, which replays the log oldest-first, lands the same
        // rows the out-of-order live ingest did.
        let database = TempDatabase()
        defer { database.remove() }
        let relay = try Fixture()
        let person = try Fixture()

        // Every stream delivered newest-first, so an unguarded projection would end
        // up holding the stale version.
        let history = try [
            relay.event(.groupMetadata, #"{"name":"New"}"#, tags: [["d", "room-1"]], at: 2000),
            relay.event(.groupMetadata, #"{"name":"Old"}"#, tags: [["d", "room-1"]], at: 1000),
            person.event(.metadata, #"{"display_name":"New"}"#, at: 2000),
            person.event(.metadata, #"{"display_name":"Old"}"#, at: 1000),
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "new"]], at: 2000),
            relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "old"]], at: 1000),
            relay.event(.threadSummary, #"{"n":2}"#, tags: [["d", "root-1"]], at: 2000),
            relay.event(.threadSummary, #"{"n":1}"#, tags: [["d", "root-1"]], at: 1000),
        ]

        var live: [String: [String]] = [:]
        do {
            let store = try database.open(projectionVersion: 1)
            _ = try await store.ingest(batch: history, phase: .backfill)

            #expect(try await store.strings("SELECT name FROM channel", column: "name") == ["New"])
            #expect(try await store.strings("SELECT display_name FROM profile", column: "display_name") == ["New"])
            #expect(try await members(store) == ["new"])
            #expect(try await store.strings("SELECT payload FROM thread_summary", column: "payload") == [#"{"n":2}"#])

            live = try await store.projectionSnapshot()
        }

        // Reopen at a bumped version: the log replays oldest-first through the real
        // projector, and must reach byte-identical projections.
        let rebuilt = try await database.open(projectionVersion: 2).projectionSnapshot()
        #expect(rebuilt == live)
    }

    // MARK: - Helpers

    private func members(_ store: BuzzEventStore) async throws -> [String] {
        try await store.strings(
            "SELECT pubkey FROM channel_member WHERE channel_id = 'room-1' ORDER BY pubkey",
            column: "pubkey"
        ).compactMap { $0 }
    }
}
