import BuzzKit
import Foundation

extension ComposerAttachmentsModel {
    /// Uploads only locally ready rows and preserves every descriptor that lands.
    /// Returning `false` leaves the draft and attachment rows in place for retry.
    func prepareForSend() async -> Bool {
        guard !isAttaching, !isUploadingForSend else { return false }
        let pending = attachments.compactMap { attachment in
            attachment.localPayload.map { (attachment.id, $0) }
        }
        guard !pending.isEmpty else {
            return attachments.count == readyDescriptors.count
        }
        guard let uploader = uploader() else {
            report(ComposerAttachmentError.noUploader)
            return false
        }

        clearError()
        for (id, payload) in pending {
            applyState(.uploading(payload), to: id)
        }
        await upload(pending, using: uploader)
        return attachments.count == readyDescriptors.count
    }

    /// Runs a send's relay work three at a time. Every child finishes so successes
    /// remain descriptors even when another child fails.
    private func upload(
        _ pending: [(UUID, ComposerAttachment.LocalPayload)],
        using uploader: any MediaUploading
    ) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            while next < min(Self.maxConcurrentUploads, pending.count) {
                let (id, payload) = pending[next]
                group.addTask { [weak self] in
                    await self?.upload(payload, as: id, using: uploader)
                }
                next += 1
            }
            while await group.next() != nil {
                guard next < pending.count else { continue }
                let (id, payload) = pending[next]
                group.addTask { [weak self] in
                    await self?.upload(payload, as: id, using: uploader)
                }
                next += 1
            }
        }
    }

    /// Uploads one scrubbed payload. Failure returns it to `.ready`, while a
    /// success drops the bytes and keeps only the descriptor for a retry.
    private func upload(
        _ payload: ComposerAttachment.LocalPayload,
        as id: UUID,
        using uploader: any MediaUploading
    ) async {
        do {
            let descriptor = try await Self.within(uploadDeadline, or: .uploadTimedOut) {
                try await uploader.upload(
                    data: payload.data,
                    mimeType: payload.mimeType,
                    filename: payload.filename
                )
            }
            applyState(.uploaded(descriptor), to: id)
        } catch is CancellationError {
            applyState(.ready(payload), to: id)
        } catch {
            applyState(.ready(payload), to: id)
            report(error)
        }
    }

    /// Runs `work`, or gives up on it. Unstructured tasks are required because a
    /// structured group cannot return until a non-cancellable loser finishes.
    static func within<T: Sendable>(
        _ deadline: Duration,
        or failure: ComposerAttachmentError,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let answer = FirstAnswer<T>()
        let working = Task {
            do { await answer.settle(.success(try await work())) } catch {
                await answer.settle(.failure(error))
            }
        }
        let timing = Task {
            guard (try? await Task.sleep(for: deadline)) != nil else { return }
            await answer.settle(.failure(failure))
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
