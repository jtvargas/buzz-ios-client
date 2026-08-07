@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
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

        try await harness.store.confirmSent(entry.event)
        #expect(try await harness.store.outboxMedia(eventID: entry.id).isEmpty)
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

    @Test("reconciliation fails an awaiting row whose staged-media records disappeared")
    func reconciliationMarksMissingMedia() async throws {
        let harness = try OutboxHarness()
        defer { harness.remove() }
        let entry = try await harness.store.enqueue(
            content: "missing picture",
            in: "room-1",
            with: harness.signer,
            state: .awaitingMedia
        )

        _ = try await harness.store.reconcileOutboxMedia()

        let reconciled = try #require(try await harness.store.entry(id: entry.id))
        #expect(reconciled.state == .failed)
        #expect(reconciled.isRetryable == false)
        #expect(reconciled.lastError == "Staged media is missing.")
    }

    @Test("awaiting media stays out of the drain until the pump uploads it")
    func awaitingMediaPump() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-pump-tests-\(UUID().uuidString)", isDirectory: true)
        let staging = MediaStagingStore(directory: directory)
        defer { try? staging.removeAll() }
        let uploader = GatedMediaUploader()
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [],
            mediaUploader: uploader,
            mediaBaseURL: URL(string: "https://relay.example.com"),
            mediaStagingStore: staging
        )
        let picture = try #require(ImageFixture.png(width: 40, height: 24))

        let entry = try await harness.engine.enqueueMediaMessage(
            text: "picture",
            in: "room-1",
            tags: [["h", "room-1"]],
            media: [OutboundMediaPayload(data: picture)]
        )
        await waitUntil { await uploader.isWaiting }

        #expect(entry.state == .awaitingMedia)
        #expect(try await harness.store.pendingSends().isEmpty)
        #expect(try await harness.store.outboxMedia(eventID: entry.id).first?.state == .uploading)
        #expect(FileManager.default.fileExists(atPath: directory.path))

        await uploader.release()
        await waitUntil { (try? await harness.store.entry(id: entry.id)?.state) == .pending }

        #expect(try await harness.store.pendingSends().map(\.id) == [entry.id])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test("discard removes an awaiting row and its unshared staged bytes inline")
    func discardAwaitingMedia() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-discard-tests-\(UUID().uuidString)", isDirectory: true)
        let staging = MediaStagingStore(directory: directory)
        defer { try? staging.removeAll() }
        let uploader = GatedMediaUploader()
        let harness = try EngineHarness(
            path: database.path,
            identity: try PrivateKey(),
            relays: [],
            mediaUploader: uploader,
            mediaBaseURL: URL(string: "https://relay.example.com"),
            mediaStagingStore: staging
        )
        let picture = try #require(ImageFixture.png(width: 40, height: 24))
        let entry = try await harness.engine.enqueueMediaMessage(
            text: "picture",
            in: "room-1",
            media: [OutboundMediaPayload(data: picture)]
        )
        await waitUntil { await uploader.isWaiting }

        try await harness.engine.discard(entry.id)

        #expect(try await harness.store.entry(id: entry.id) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        await uploader.release()
    }
}

private actor GatedMediaUploader: MediaUploading {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var isWaiting = false

    func upload(data: Data, mimeType _: String, filename _: String?) async throws -> BlobDescriptor {
        isWaiting = true
        await withCheckedContinuation { continuation = $0 }
        return BlobDescriptor(
            url: "https://relay.example.com/media/uploaded.png",
            sha256: MediaUploadClient.sha256Hex(data),
            size: data.count,
            type: "image/png",
            uploaded: 1
        )
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
