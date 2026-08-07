import Foundation
import NostrCore

public extension SyncEngine {
    /// Stages a media message durably, commits it as authored-but-held, and starts
    /// its uploads above the view tree. The ordinary outbox drain sees it only
    /// after every staged blob has landed.
    @discardableResult
    func enqueueMediaMessage(
        kind: EventKind = .channelMessage,
        text: String,
        in channel: String,
        tags: [[String]] = [],
        media: [OutboundMediaPayload],
        maxContentBytes: Int = OutboxPolicy.maxContentBytes
    ) async throws -> OutboxEntry {
        guard let mediaBaseURL, mediaUploader != nil, let mediaStagingStore else {
            throw OutboxError.mediaUnavailable
        }

        var descriptors: [BlobDescriptor] = []
        var rows: [OutboxMedia] = []
        do {
            for (ordinal, payload) in media.enumerated() {
                guard let descriptor = BlobDescriptor.predicted(
                    data: payload.data,
                    baseURL: mediaBaseURL,
                    filename: payload.filename
                ) else { throw OutboxError.mediaStagingFailed }
                let key = StagedMediaKey(
                    sha256: descriptor.sha256,
                    fileExtension: URL(string: descriptor.url)?.pathExtension ?? ""
                )
                try mediaStagingStore.write(payload.data, for: key)
                descriptors.append(descriptor)
                rows.append(OutboxMedia(
                    sha256: descriptor.sha256,
                    ordinal: ordinal,
                    fileExtension: key.fileExtension,
                    mimeType: descriptor.type,
                    size: descriptor.size
                ))
            }
        } catch {
            try? await cleanUnreferencedStagedMedia()
            throw OutboxError.mediaStagingFailed
        }

        do {
            let content = ([text] + descriptors.map { $0.markdownReference() })
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let entry = try await store.enqueue(
                kind: kind,
                content: content,
                in: channel,
                tags: tags + descriptors.map { $0.imetaTag() },
                with: signer,
                maxContentBytes: maxContentBytes,
                media: rows,
                state: .awaitingMedia
            )
            Task { [weak self] in await self?.pumpMedia(eventID: entry.id) }
            return entry
        } catch {
            try? await cleanUnreferencedStagedMedia()
            throw error
        }
    }
}

private extension SyncEngine {
    func pumpMedia(eventID: String) async {
        guard mediaUploader != nil, mediaStagingStore != nil,
              let records = try? await store.outboxMedia(eventID: eventID, unfinishedOnly: true)
        else { return }

        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(3, records.count) {
                let record = records[next]
                group.addTask { [weak self] in await self?.upload(record) }
                next += 1
            }
            while await group.next() != nil {
                guard next < records.count else { continue }
                let record = records[next]
                group.addTask { [weak self] in await self?.upload(record) }
                next += 1
            }
        }

        guard (try? await store.releaseAwaitingMedia(eventID)) == true else { return }
        await drainOutbox()
    }

    func upload(_ record: OutboxMediaRecord) async {
        guard let mediaUploader, let mediaStagingStore else { return }
        do {
            let data = try mediaStagingStore.data(for: record.key)
            try await store.markOutboxMediaUploading(record)
            _ = try await mediaUploader.upload(data: data, mimeType: record.mimeType, filename: nil)
            try await store.markOutboxMediaUploaded(record)
            if try await store.canRemoveStagedFile(record.key) {
                try mediaStagingStore.remove(record.key)
            }
        } catch {
            try? await store.markOutboxMediaFailed(record, error: String(describing: error))
        }
    }

    func cleanUnreferencedStagedMedia() async throws {
        guard let mediaStagingStore else { return }
        let retained = try await store.reconcileOutboxMedia()
        try mediaStagingStore.sweep(retaining: retained)
    }
}
