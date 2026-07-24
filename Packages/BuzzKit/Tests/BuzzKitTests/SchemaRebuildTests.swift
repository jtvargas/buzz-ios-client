@testable import BuzzKit
import Foundation
import NostrCore
import Testing

@Suite("Projection rebuild", .timeLimit(.minutes(1)))
struct SchemaRebuildTests {
    /// A mixed history touching several kinds, deliberately supplied out of
    /// created_at order so replay ordering is actually exercised.
    private static func mixedHistory(_ fixture: Fixture) throws -> [NostrEvent] {
        try [
            fixture.event(.groupMetadata, #"{"name":"New"}"#, tags: [["d", "room-1"]], at: 1200),
            fixture.event(.groupMetadata, #"{"name":"Old"}"#, tags: [["d", "room-1"]], at: 900),
            fixture.message("hello", at: 1000),
            fixture.event(.metadata, #"{"display_name":"Ada"}"#, at: 950),
            fixture.event(.groupMembers, "", tags: [["d", "room-1"], ["p", "alice"]], at: 1100),
        ]
    }

    /// The order the store must replay in: created_at ascending, id as tiebreak.
    private static func logOrder(_ events: [NostrEvent]) -> [String] {
        events.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }.map(\.id)
    }

    @Test("a forced rebuild drops projections and replays the log through the seam, in order")
    func forcedRebuildDropsAndReplaysInOrder() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let fixture = try Fixture()
        let history = try Self.mixedHistory(fixture)

        let recorder = RecordingProjector()
        let store = try database.open(projector: recorder)
        _ = try await store.ingest(batch: history, phase: .backfill)

        // Live ingest already drove the seam once, per inserted event.
        #expect(Set(recorder.events.map(\.id)) == Set(history.map(\.id)))

        // A row a correct rebuild must erase — proof the drop actually happens,
        // since the recording projector writes no projection rows of its own.
        try await store.executeForTest("""
        INSERT INTO channel (id, name, about, picture, is_private, source_event_id, updated_at)
        VALUES ('sentinel', 'x', NULL, NULL, 0, 'e', 1)
        """)
        #expect(try await store.rowCount("channel") == 1)

        recorder.reset()
        try await store.rebuildProjections()

        #expect(try await store.rowCount("channel") == 0)
        #expect(recorder.events.map(\.id) == Self.logOrder(history))
    }

    @Test("a bumped projection version at open drops projections and replays through the seam")
    func versionBumpOnOpenReplaysThroughSeam() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let fixture = try Fixture()
        let history = try Self.mixedHistory(fixture)

        // First open at version 1: ingest the whole log and stamp the version.
        do {
            let store = try database.open(projectionVersion: 1)
            _ = try await store.ingest(batch: history, phase: .backfill)
            #expect(try await store.count() == history.count)
            #expect(try await store.metaValue(Schema.projectionVersionKey) == "1")
        }

        // Reopen at a bumped version: init must replay the whole log through the
        // seam, in log order, and stamp the new version.
        let recorder = RecordingProjector()
        let reopened = try database.open(projector: recorder, projectionVersion: 2)

        #expect(recorder.events.map(\.id) == Self.logOrder(history))
        #expect(try await reopened.metaValue(Schema.projectionVersionKey) == "2")
    }

    @Test("a matching projection version at open does not rebuild")
    func matchingVersionOnOpenSkipsRebuild() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let fixture = try Fixture()

        do {
            let store = try database.open(projectionVersion: 7)
            _ = try await store.ingest(batch: [fixture.message("stored")], phase: .live)
        }

        let recorder = RecordingProjector()
        _ = try database.open(projector: recorder, projectionVersion: 7)
        #expect(recorder.events.isEmpty)
    }

    @Test("rebuild leaves the log untouched")
    func rebuildPreservesLog() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let fixture = try Fixture()
        let history = try Self.mixedHistory(fixture)

        let store = try database.open()
        _ = try await store.ingest(batch: history, phase: .backfill)
        let before = try await store.count()

        try await store.rebuildProjections()

        #expect(try await store.count() == before)
        for event in history {
            #expect(try await store.event(id: event.id) == event)
        }
    }
}
