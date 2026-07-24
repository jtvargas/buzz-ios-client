@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// The read-time authority matrix (spec T8). Deletions and edits are recorded by
/// the projector without judgment; these tests pin which of them the timeline
/// query actually honours.
@Suite("Read-time authority", .timeLimit(.minutes(1)))
struct AuthorityTests {
    @Test("a kind-5 from the author deletes; from a stranger it does not")
    func authorVersusStranger() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let stranger = try Fixture()
        let owned = try author.message("author will delete this", at: 1000)
        let other = try author.message("stranger cannot delete this", at: 1001)

        _ = try await store.ingest(batch: [
            owned, other,
            author.event(.deletion, "", tags: [["e", owned.id]], at: 1002),
            stranger.event(.deletion, "", tags: [["e", other.id]], at: 1003),
        ], phase: .backfill)

        let rows = try timelineByID(store)
        #expect(rows[owned.id]?.isDeleted == true)
        #expect(rows[other.id]?.isDeleted == false)
    }

    @Test("a kind-9005 relay tombstone deletes no matter who signed it")
    func relayTombstone() async throws {
        // In NIP-29 the relay is the group's moderation authority, so a 9005 it
        // accepted is honoured from anyone.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let moderator = try Fixture()
        let message = try author.message("moderated away", at: 1000)

        _ = try await store.ingest(batch: [
            message,
            moderator.event(.groupDeleteEvent, "", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try #require(try store.timeline(channel: "room-1").first).isDeleted)
    }

    @Test("a verified NIP-OA owner may delete and edit an agent's message; a third party may not")
    func ownerWidening() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let owner = try Fixture()
        let agent = try Fixture()
        let stranger = try Fixture()
        let auth = try owner.authTag(authorizing: agent.pubkey)

        let deletable = try agent.event(
            .channelMessage, "owner deletes this", tags: [["h", "room-1"], auth], at: 1000
        )
        let editable = try agent.event(
            .channelMessage, "owner edits this", tags: [["h", "room-1"], auth], at: 1001
        )
        let untouchable = try agent.event(
            .channelMessage, "stranger touches nothing", tags: [["h", "room-1"], auth], at: 1002
        )

        _ = try await store.ingest(batch: [
            deletable, editable, untouchable,
            // The verified owner acts on the agent's messages.
            owner.event(.deletion, "", tags: [["e", deletable.id]], at: 1003),
            owner.event(.messageEdit, "edited by owner", tags: [["e", editable.id]], at: 1004),
            // A third party who is neither author nor owner acts on another.
            stranger.event(.deletion, "", tags: [["e", untouchable.id]], at: 1005),
            stranger.event(.messageEdit, "hacked", tags: [["e", untouchable.id]], at: 1006),
        ], phase: .backfill)

        let rows = try timelineByID(store)
        #expect(rows[deletable.id]?.isDeleted == true)
        #expect(rows[editable.id]?.content == "edited by owner")
        #expect(rows[editable.id]?.isEdited == true)
        #expect(rows[untouchable.id]?.isDeleted == false)
        #expect(rows[untouchable.id]?.content == "stranger touches nothing")
        #expect(rows[untouchable.id]?.isEdited == false)
    }

    @Test("an unverifiable owner attestation grants no authority")
    func unverifiableAttestation() async throws {
        // The claimed owner's signature does not check out, so no attestation is
        // recorded and the claimed owner's deletion is ignored — the same as any
        // stranger's.
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let owner = try Fixture()
        let agent = try Fixture()

        var forgedTag = try owner.authTag(authorizing: agent.pubkey)
        forgedTag[3] = String(forgedTag[3].dropLast()) + (forgedTag[3].hasSuffix("0") ? "1" : "0")
        let message = try agent.event(
            .channelMessage, "claims an owner it cannot prove", tags: [["h", "room-1"], forgedTag], at: 1000
        )

        _ = try await store.ingest(batch: [
            message,
            owner.event(.deletion, "", tags: [["e", message.id]], at: 1001),
        ], phase: .backfill)

        #expect(try #require(try store.timeline(channel: "room-1").first).isDeleted == false)
    }

    private func timelineByID(_ store: BuzzEventStore) throws -> [String: TimelineRow] {
        Dictionary(uniqueKeysWithValues: try store.timeline(channel: "room-1").map { ($0.id, $0) })
    }
}
