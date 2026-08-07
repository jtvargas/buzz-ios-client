import Foundation

extension ComposerAttachmentsModel {
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
            do {
                try await Task.sleep(for: deadline)
                await answer.settle(.failure(failure))
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
