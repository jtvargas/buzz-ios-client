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
                    filename: payload.filename,
                    mimeType: payload.mimeType
                ) else { throw OutboxError.mediaStagingFailed }
                // **Not taken from the predicted URL for a file.** A file's URL is a
                // bare hash on purpose, so its `pathExtension` is empty — and an empty
                // one is refused by `MediaStagingStore`, which builds a real filename
                // from this and rejects anything that would not make one
                // (`OutboxMedia.swift:120-127`). That refusal is right; it is this key
                // that had no business being derived from the URL.
                //
                // The two are unrelated concerns. This names a file in a local staging
                // directory; the URL names a blob on the relay. Nothing reads this back
                // as a type — the upload sends `mimeType` from the row beside it — so
                // `bin` for opaque bytes is both valid and honest.
                let predictedExtension = URL(string: descriptor.url)?.pathExtension ?? ""
                let key = StagedMediaKey(
                    sha256: descriptor.sha256,
                    fileExtension: predictedExtension.isEmpty ? "bin" : predictedExtension
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

    /// How many of a message's pictures go up at once.
    ///
    /// **Two, because that is what the relay allows** — `buzz-relay` caps concurrent
    /// uploads per pubkey at `BUZZ_MEDIA_MAX_CONCURRENT_UPLOADS_PER_PUBKEY`, default
    /// 2 (`config.rs`). This was 3, and the third upload of every five-picture
    /// message was refused with a 429 the instant it started — measured against a
    /// live relay, five at once, two accepted and three refused.
    ///
    /// So this number is not a throughput knob. **Raising it re-breaks five
    /// pictures** unless the relay's ceiling moves first. The backoff in
    /// ``upload(_:)`` is what makes us correct rather than merely lucky: another
    /// device signed in as the same person can still take the budget.
    static let maxConcurrentMediaUploads = 2

    /// How long to wait before offering a refused upload again, and how many times.
    ///
    /// Short and few on purpose: a 429 clears as soon as one of our own two slots
    /// frees, which is the length of one upload, not a server outage.
    static let concurrencyBackoff: Duration = .seconds(2)
    static let concurrencyRetryLimit = 4

    private func pumpMedia(eventID: String) async {
        guard mediaUploader != nil, mediaStagingStore != nil,
              let records = try? await store.outboxMedia(eventID: eventID, unfinishedOnly: true)
        else { return }

        let failures = await withTaskGroup(
            of: MediaPumpFailure?.self,
            returning: [MediaPumpFailure].self
        ) { group in
            var failures: [MediaPumpFailure] = []
            var next = 0
            while next < min(Self.maxConcurrentMediaUploads, records.count) {
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

        if let failure = failures.first(where: { !$0.isRetryable }) ?? failures.first {
            try? await store.markFailed(
                eventID,
                error: failure.message,
                retryable: failure.isRetryable
            )
            return
        }
        guard (try? await store.releaseAwaitingMedia(eventID)) == true else { return }
        await drainOutbox()
    }

    private func upload(_ record: OutboxMediaRecord) async -> MediaPumpFailure? {
        guard let mediaUploader, let mediaStagingStore else {
            return MediaPumpFailure(message: "Media upload is unavailable.", isRetryable: true)
        }
        do {
            let data = try mediaStagingStore.data(for: record.key)
            try await store.markOutboxMediaUploading(record)
            // Refusal-for-being-busy is retried here rather than surfaced, because it
            // says nothing about this picture: the relay is holding as many of our
            // uploads as it will take and one is about to finish. Every other error
            // falls straight through to the catch below on its first occurrence.
            var attempt = 0
            while true {
                do {
                    _ = try await Self.within(config.mediaUploadDeadline) {
                        try await mediaUploader.upload(
                            data: data,
                            mimeType: record.mimeType,
                            filename: nil
                        )
                    }
                    break
                } catch MediaUploadError.tooManyConcurrent {
                    attempt += 1
                    guard attempt <= Self.concurrencyRetryLimit else {
                        throw MediaUploadError.tooManyConcurrent
                    }
                    try await Task.sleep(for: Self.concurrencyBackoff)
                }
            }
            try await store.markOutboxMediaUploaded(record)
            if try await store.canRemoveStagedFile(record.key) {
                try mediaStagingStore.remove(record.key)
            }
            return nil
        } catch {
            let failure = Self.describeMediaFailure(error)
            try? await store.markOutboxMediaFailed(record, error: failure.message)
            return failure
        }
    }

    private static func describeMediaFailure(_ error: any Error) -> MediaPumpFailure {
        switch error {
        case MediaUploadError.rejectedByPolicy:
            MediaPumpFailure(message: "The relay wouldn't store that picture.", isRetryable: false)
        case MediaUploadError.unsupportedType:
            MediaPumpFailure(message: "That kind of file can't be sent yet.", isRetryable: false)
        case is MediaUploadDeadlineExceeded:
            MediaPumpFailure(message: "A picture upload timed out.", isRetryable: true)
        case MediaUploadError.tooManyConcurrent:
            // Only reachable once the backoff in ``upload(_:)`` has given up, so it
            // is a busy relay rather than our own concurrency — and it says so, in
            // case anyone reads this string and starts looking at the picture.
            MediaPumpFailure(message: "The relay was too busy for that picture.", isRetryable: true)
        default:
            MediaPumpFailure(message: "A picture could not be uploaded.", isRetryable: true)
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
            do {
                try await Task.sleep(for: deadline)
                await answer.settle(.failure(MediaUploadDeadlineExceeded()))
            } catch {
                await answer.settle(.failure(error))
            }
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

private struct MediaPumpFailure: Sendable {
    let message: String
    let isRetryable: Bool
}

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
