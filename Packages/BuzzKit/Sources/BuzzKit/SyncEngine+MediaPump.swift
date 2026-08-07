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
        var stagedKeys: [StagedMediaKey] = []
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
                stagedKeys.append(key)
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
            await cleanStagedMedia(stagedKeys)
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
            scheduleMediaPump(eventID: entry.id)
            return entry
        } catch {
            await cleanStagedMedia(stagedKeys)
            throw error
        }
    }

    /// Restarts every authored event held for media. Called at mount and by every
    /// drain trigger so a process death or lost network edge cannot strand a row.
    func resumeMediaUploads() async {
        guard mediaUploader != nil, mediaStagingStore != nil,
              let eventIDs = try? await store.awaitingMediaEventIDs()
        else { return }
        for eventID in eventIDs { scheduleMediaPump(eventID: eventID) }
    }
}

extension SyncEngine {
    func scheduleMediaPump(eventID: String, retryIfRunning: Bool = false) {
        guard mediaPumpsInFlight.insert(eventID).inserted else {
            if retryIfRunning { mediaPumpRetriesPending.insert(eventID) }
            return
        }
        Task { [weak self] in
            await self?.runMediaPump(eventID: eventID)
        }
    }

    private func runMediaPump(eventID: String) async {
        await pumpMedia(eventID: eventID)
        mediaPumpsInFlight.remove(eventID)
        // A human can tap retry after the failed state commits but before this task
        // unwinds. Carry that trigger across the old pump's final actor turn.
        if mediaPumpRetriesPending.remove(eventID) != nil {
            scheduleMediaPump(eventID: eventID)
        }
    }

    private func pumpMedia(eventID: String) async {
        guard mediaUploader != nil, mediaStagingStore != nil,
              let records = try? await store.outboxMedia(eventID: eventID, unfinishedOnly: true)
        else { return }

        let failures = await withTaskGroup(of: String?.self, returning: [String].self) { group in
            var failures: [String] = []
            var next = 0
            while next < min(3, records.count) {
                let record = records[next]
                group.addTask { [weak self] in await self?.upload(record) }
                next += 1
            }
            while let result = await group.next() {
                if let result { failures.append(result) }
                guard next < records.count else { continue }
                let record = records[next]
                group.addTask { [weak self] in await self?.upload(record) }
                next += 1
            }
            return failures
        }

        if let failure = failures.first {
            try? await store.markFailed(eventID, error: failure, retryable: true)
            return
        }
        guard (try? await store.releaseAwaitingMedia(eventID)) == true else { return }
        await drainOutbox()
    }

    private func upload(_ record: OutboxMediaRecord) async -> String? {
        guard let mediaUploader, let mediaStagingStore else { return "Media upload is unavailable." }
        do {
            let data = try mediaStagingStore.data(for: record.key)
            try await store.markOutboxMediaUploading(record)
            _ = try await Self.within(config.mediaUploadDeadline) {
                try await mediaUploader.upload(data: data, mimeType: record.mimeType, filename: nil)
            }
            try await store.markOutboxMediaUploaded(record)
            if try await store.canRemoveStagedFile(record.key) {
                try mediaStagingStore.remove(record.key)
            }
            return nil
        } catch {
            let detail = error is MediaUploadDeadlineExceeded
                ? "A picture upload timed out."
                : "A picture could not be uploaded."
            try? await store.markOutboxMediaFailed(record, error: detail)
            return detail
        }
    }

    /// Removes only files written for this failed enqueue, and only when no
    /// committed media row needs them. Startup reconciliation owns global sweeps.
    private func cleanStagedMedia(_ keys: [StagedMediaKey]) async {
        guard let mediaStagingStore else { return }
        for key in Set(keys) where (try? await store.canRemoveStagedFile(key)) == true {
            try? mediaStagingStore.remove(key)
        }
    }

    /// Runs work outside a structured group so a non-cancellable uploader cannot
    /// keep the timeout path waiting for its losing task.
    private static func within<T: Sendable>(
        _ deadline: Duration,
        work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let answer = MediaUploadFirstAnswer<T>()
        let working = Task {
            do { await answer.settle(.success(try await work())) } catch {
                await answer.settle(.failure(error))
            }
        }
        let timing = Task {
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            await answer.settle(.failure(MediaUploadDeadlineExceeded()))
        }
        defer {
            working.cancel()
            timing.cancel()
        }
        return try await withTaskCancellationHandler {
            try await answer.value().get()
        } onCancel: {
            Task { await answer.settle(.failure(CancellationError())) }
        }
    }
}

private struct MediaUploadDeadlineExceeded: Error {}

private actor MediaUploadFirstAnswer<T: Sendable> {
    private var answer: Result<T, any Error>?
    private var waiter: CheckedContinuation<Result<T, any Error>, Never>?

    func settle(_ result: Result<T, any Error>) {
        guard answer == nil else { return }
        answer = result
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: result)
        }
    }

    func value() async -> Result<T, any Error> {
        if let answer { return answer }
        return await withCheckedContinuation { waiter = $0 }
    }
}
