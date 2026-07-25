@testable import BuzzKit
import Foundation
import NostrCore
import NostrCoreTestSupport
import Testing

/// The cold-start presence snapshot: the engine names every known roster member as an
/// author on a one-shot `kind:20001` REQ, the relay answers with synthesized
/// presence, and the roster is populated at launch rather than a heartbeat interval
/// later. Covers the store's member-roster read and the engine's end-to-end wiring.
@Suite("Cold-start presence snapshot", .timeLimit(.minutes(1)))
struct PresenceSnapshotTests {
    // MARK: - Store: member roster read

    @Test("allMemberPubkeys collects distinct members across channel rosters")
    func memberPubkeysAcrossRosters() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let relay = try Fixture()
        let alice = try Fixture()
        let bob = try Fixture()

        _ = try await store.ingest(batch: [
            // A relay-signed roster (kind 39002) names its members in `p` tags.
            try relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", alice.pubkey], ["p", bob.pubkey]]),
            // A second channel where bob is also a member — deduped in the union.
            try relay.event(.groupMembers, "", tags: [["d", "room-2"], ["p", bob.pubkey]]),
        ], phase: .backfill)

        let members = try await store.allMemberPubkeys()
        #expect(members == [alice.pubkey, bob.pubkey])
    }

    @Test("allMemberPubkeys is empty before any roster is discovered")
    func memberPubkeysEmptyWithoutRosters() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        #expect(try await store.allMemberPubkeys().isEmpty)
    }

    // MARK: - Engine: end-to-end cold start

    @Test("on ready, requests presence for discovered members and populates the roster")
    func coldStartPopulatesRoster() async throws {
        let socket = ScriptedRelay()
        let database = TempDatabase()
        defer { database.remove() }
        let harness = try EngineHarness(
            path: database.path, identity: try PrivateKey(), relays: [socket]
        )
        let fixtures = try EngineFixtures()
        let subject = try Fixture() // an online member the relay will report

        try await harness.engine.start()
        try await driveAuth(harness.connection, socket)

        // Discovery carries the channel metadata and a roster naming `subject`, so the
        // member projection is populated before the snapshot REQ reads it.
        let roster = try fixtures.relay.event(
            .groupMembers, "", tags: [["d", "room"], ["p", subject.pubkey]]
        )
        await answerDiscovery(on: socket, events: [
            try fixtures.metadata(for: "room", name: "Room"),
            roster,
        ])

        // The engine now issues the snapshot REQ: all filters target kind:20001 with a
        // non-empty authors list. Answer it with a synthesized presence event —
        // relay-signed, the subject carried in a `p` tag.
        let snapshotID = await awaitREQ(on: socket) { filters in
            filters.count == 1
                && filters[0].kinds == [.presence]
                && (filters[0].authors?.contains(subject.pubkey) ?? false)
        }
        let synthesized = try fixtures.relay.event(
            .presence, "online", tags: [["p", subject.pubkey]], at: harness.nowSeconds
        )
        await socket.enqueue(EngineFrames.event(snapshotID, synthesized))
        await socket.enqueue(EngineFrames.eose(snapshotID))

        // The roster shows the subject online — keyed by the `p`-tag subject, not the
        // relay author that signed the synthesized event.
        await waitUntil {
            await harness.presence.workspacePresenceSnapshot().map(\.pubkey) == [subject.pubkey]
        }

        await harness.engine.stop()
    }
}
