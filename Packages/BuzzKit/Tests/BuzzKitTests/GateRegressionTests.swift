@testable import BuzzKit
import Foundation
import NostrCore
import Testing

/// Regressions for the Phase-2 reliability-review gate findings that live at the
/// store, timeline, and projection layers. The engine-level findings (P2-3, P3-2)
/// have their own file. Each test here fails against the pre-fix code; the method
/// that proves it is noted per finding in the PR report.
@Suite("Phase-2 gate regressions (store/timeline/projections)", .timeLimit(.minutes(1)))
struct GateRegressionTests {
    // MARK: - P2-1: multi-target deletion tombstones every target

    /// One kind-5 naming several `e` targets must tombstone *all* of them. With the
    /// deletion table keyed by `event_id` alone, `ON CONFLICT(event_id) DO NOTHING`
    /// kept only the first target's row and silently dropped the rest; the composite
    /// `(event_id, target_id)` key keeps one row per target.
    @Test("a multi-target kind-5 deletes every target, live and after a rebuild")
    func multiTargetDeletionCoversEveryTarget() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()

        let first = try author.message("first target", at: 1000)
        let second = try author.message("second target", at: 1001)
        // A single deletion (authorized — same author) naming both messages.
        let deletion = try author.event(
            .deletion, "", tags: [["e", first.id], ["e", second.id]], at: 1002
        )

        _ = try await store.ingest(batch: [first, second, deletion], phase: .backfill)

        // One deletion row per target, and both targets render deleted.
        #expect(try await store.rowCount("deletion") == 2)
        let live = try rowsByID(store)
        #expect(live[first.id]?.isDeleted == true)
        #expect(live[second.id]?.isDeleted == true)

        // Rebuild agreement: a version-bump replay reproduces both tombstones.
        let liveSnapshot = try await store.projectionSnapshot()
        try await store.rebuildProjections()
        #expect(try await store.projectionSnapshot() == liveSnapshot)
        let rebuilt = try rowsByID(store)
        #expect(rebuilt[first.id]?.isDeleted == true)
        #expect(rebuilt[second.id]?.isDeleted == true)
    }

    // MARK: - P2-2: a message in both the log and the outbox renders once

    /// The T3 recovery state: a send is queued and handed to the relay, then the
    /// same event lands in the log before the OK confirms the queue row (a relaunch
    /// reconcile stored it, or a relay echo beat the OK). The timeline must show one
    /// row — the log row, delivered `.sent` — not a second `.pending` copy of the
    /// same id.
    @Test("a message present in both the log and a live outbox row renders once, as sent")
    func outboxRowSuppressedOnceLogged() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(
            content: "hello", in: "room-1", tags: [["h", "room-1"]], with: harness.signer
        )
        try await store.markSending(entry.id)

        // The same signed event enters the log while the queue row still stands.
        _ = try await store.ingest(batch: [entry.event], phase: .live)

        let rows = try store.timeline(channel: "room-1")
        #expect(rows.count == 1)
        #expect(rows.first?.id == entry.event.id)
        #expect(rows.first?.delivery == .sent)
    }

    // MARK: - P2-4: same-second replaceable ties resolve by event id

    /// Two replaceables of the same kind sharing a `created_at` must collapse to the
    /// same survivor — the higher event id — whatever order they arrive in live, and
    /// identically under an id-ordered rebuild replay. Strict-on-time guards diverged
    /// here: live kept first-arrival, the rebuild kept the id-ordered winner.
    @Test(
        "same-second replaceable ties break by event id, identically live and rebuilt",
        arguments: [false, true]
    )
    func sameSecondReplaceableTie(reversedArrival: Bool) async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let relay = try Fixture()

        // Two rosters and two channel-metas sharing created_at; only the id differs.
        let rosterAlice = try relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"]], at: 2000)
        let rosterBob = try relay.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "bob"]], at: 2000)
        let metaOne = try relay.event(.groupMetadata, #"{"name":"One"}"#, tags: [["d", "room-1"]], at: 2000)
        let metaTwo = try relay.event(.groupMetadata, #"{"name":"Two"}"#, tags: [["d", "room-1"]], at: 2000)

        // The expected survivor of each pair is the higher event id.
        let winningRoster = rosterAlice.id > rosterBob.id ? rosterAlice : rosterBob
        let expectedMember = winningRoster.firstValue(forTag: "p")
        let expectedName = metaOne.id > metaTwo.id ? "One" : "Two"

        let batch = reversedArrival
            ? [rosterBob, rosterAlice, metaTwo, metaOne]
            : [rosterAlice, rosterBob, metaOne, metaTwo]

        let store = try database.open(projectionVersion: 1)
        _ = try await store.ingest(batch: batch, phase: .backfill)

        // The higher-id source won, whatever the arrival order.
        #expect(try await store.strings(
            "SELECT pubkey FROM channel_member WHERE channel_id = 'room-1'", column: "pubkey"
        ) == [expectedMember])
        #expect(try await store.strings(
            "SELECT name FROM channel WHERE id = 'room-1'", column: "name"
        ) == [expectedName])
        let live = try await store.projectionSnapshot()

        // A rebuild replays oldest-first by (created_at, id) and must land the same rows.
        let rebuilt = try await database.open(projectionVersion: 2).projectionSnapshot()
        #expect(rebuilt == live)
    }

    // MARK: - P3-1: confirmSent runs the ingest choke point's dual check

    /// `confirmSent` gates on the store's own `verify` — id **and** signature — the
    /// same admission the ingest choke point uses, so an id-tampered event is
    /// rejected and nothing enters the log through the confirm path.
    ///
    /// Coverage note: this pins the confirm-path contract. It does not by itself
    /// distinguish the fix from the pre-fix `isValid`-only guard, because
    /// `NostrEvent.isValid` already subsumes `hasValidID` — see the PR report.
    @Test("confirmSent rejects an id-tampered event and writes nothing to the log")
    func confirmSentRejectsIDTamper() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let store = harness.store

        let entry = try await store.enqueue(content: "confirm me", in: "room-1", with: harness.signer)
        let realID = entry.event.id
        let tamperedID = String(realID.dropLast()) + (realID.hasSuffix("0") ? "1" : "0")
        let tampered = NostrEvent(
            id: tamperedID,
            pubkey: entry.event.pubkey,
            createdAt: entry.event.createdAt,
            kind: entry.event.kind,
            tags: entry.event.tags,
            content: entry.event.content,
            sig: entry.event.sig
        )

        await #expect(throws: OutboxError.invalidEvent(tamperedID)) {
            try await store.confirmSent(tampered)
        }
        #expect(try await store.count() == 0)
        #expect(try await store.outboxCount() == 1)
    }

    // MARK: - Helpers

    private func rowsByID(_ store: BuzzEventStore) throws -> [String: TimelineRow] {
        Dictionary(uniqueKeysWithValues: try store.timeline(channel: "room-1").map { ($0.id, $0) })
    }
}
