@testable import BuzzKit
import Foundation
import GRDB
import Testing

@Suite("Outbox media staging")
struct OutboxMediaTests {
    @Test("enqueue commits the outbox row and its media rows together")
    func enqueueWithMedia() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let media = OutboxMedia(
            sha256: String(repeating: "a", count: 64),
            ordinal: 0,
            fileExtension: "jpg",
            mimeType: "image/jpeg",
            size: 3
        )

        let entry = try await harness.store.enqueue(
            content: "photo",
            in: "room-1",
            with: harness.signer,
            media: [media]
        )

        let rows = try await harness.store.reader.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbox_media WHERE event_id = ?", arguments: [entry.id])
        }
        #expect(rows.count == 1)
        #expect(rows[0]["sha256"] == media.sha256)
        #expect(rows[0]["ordinal"] == media.ordinal)
        #expect(rows[0]["state"] == OutboxMediaState.staged.rawValue)
    }

    @Test("reconciliation removes orphan rows and files but keeps shared staged bytes")
    func reconciliation() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let stagingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-staging-tests-\(UUID().uuidString)", isDirectory: true)
        let staging = MediaStagingStore(directory: stagingDirectory)
        defer { try? staging.removeAll() }
        let kept = StagedMediaKey(sha256: String(repeating: "b", count: 64), fileExtension: "jpg")
        let orphan = StagedMediaKey(sha256: String(repeating: "c", count: 64), fileExtension: "png")
        _ = try staging.write(Data([1]), for: kept)
        _ = try staging.write(Data([2]), for: orphan)

        let fixture = try Fixture()
        let event = try fixture.message("photo")
        try await store.writer.write { db in
            try BuzzEventStore.insertOutboxRow(event, channel: "room-1", state: .pending, into: db)
            try db.execute(
                sql: "INSERT INTO outbox_media VALUES (?, ?, 0, 'jpg', 'image/jpeg', 1, 'staged', 0, NULL)",
                arguments: [event.id, kept.sha256]
            )
            try db.execute(
                sql: "INSERT INTO outbox_media VALUES ('missing', ?, 0, 'png', 'image/png', 1, 'staged', 0, NULL)",
                arguments: [orphan.sha256]
            )
        }

        let retained = try await store.reconcileOutboxMedia()
        try staging.sweep(retaining: retained)

        #expect(retained == Set([kept]))
        #expect(try staging.data(for: kept) == Data([1]))
        #expect(throws: (any Error).self) { try staging.data(for: orphan) }
    }
}
