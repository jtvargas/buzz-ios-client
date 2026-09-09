import Foundation
import NostrCore
import OSLog

extension SyncEngine {
    /// All callers join the same request. Cancelling one caller leaves the work alive
    /// for another caller or a screen that is still observing this root.
    @discardableResult
    public func openThread(root: String) async throws -> [NostrEvent] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard !isStopped else {
                    continuation.resume(throwing: RelayConnectionError.stopped)
                    return
                }
                let request = threadRequest(root)
                request.waiters[id] = continuation
                startThreadLoad(root, request: request)
            }
        } onCancel: {
            Task { await self.cancelThreadWaiter(root: root, id: id) }
        }
    }

    public func threadLoadStates(root: String) -> AsyncStream<ThreadLoadState>? {
        let request = threadRequest(root)
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: ThreadLoadState.self, bufferingPolicy: .bufferingNewest(1)
        )
        request.observers[id] = continuation
        continuation.yield(request.state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeThreadObserver(root: root, id: id) }
        }
        return stream
    }

    /// A fresh authenticated socket refreshes the actual open screens immediately.
    /// It does not wait for the directory's general catch-up pass to reach their roots.
    func updateThreadConnection(_ state: ConnectionState) {
        threadLoading.connectionIsReady = state == .ready
        threadLoading.terminalFailure = if case .stopped(.authRejected) = state { .accessDenied } else { nil }
        for (root, request) in threadLoading.requests {
            guard !request.observers.isEmpty || !request.waiters.isEmpty else { continue }
            if state == .ready {
                startThreadLoad(root, request: request)
            } else {
                request.token = UUID()
                request.task?.cancel()
                request.task = nil
                if case .stopped(.authRejected) = state {
                    setThreadState(.failed(.accessDenied), request: request)
                    finishThreadWaiters(request, result: .failure(ThreadLoadFailure.accessDenied))
                } else {
                    setThreadState(.waitingForConnection, request: request)
                }
            }
        }
    }

    func stopThreadLoading() {
        threadLoading.connectionIsReady = false
        let requests = threadLoading.requests.values
        threadLoading.requests.removeAll()
        for request in requests {
            request.task?.cancel()
            finishThreadWaiters(request, result: .failure(CancellationError()))
            for observer in request.observers.values {
                observer.finish()
            }
        }
    }

    private func threadRequest(_ root: String) -> ThreadLoadContext.Request {
        if let request = threadLoading.requests[root] { return request }
        let request = ThreadLoadContext.Request()
        threadLoading.requests[root] = request
        return request
    }

    private func startThreadLoad(_ root: String, request: ThreadLoadContext.Request) {
        guard request.task == nil else { return }
        if let failure = threadLoading.terminalFailure {
            setThreadState(.failed(failure), request: request)
            finishThreadWaiters(request, result: .failure(failure))
            discardUnobservedThread(root, request: request)
            return
        }
        guard threadLoading.connectionIsReady else {
            setThreadState(.waitingForConnection, request: request)
            return
        }
        let token = UUID()
        request.token = token
        setThreadState(.loading, request: request)
        request.task = Task { [weak self] in
            await self?.performThreadLoad(root, token: token)
        }
    }

    private func performThreadLoad(_ root: String, token: UUID) async {
        for attempt in 0 ..< 3 {
            do {
                try Task.checkCancellation()
                let limit = config.threadFetchLimit
                let filter = Filter(kinds: [.channelMessage], limit: limit, tagQueries: ["e": [root]])
                let events = try await queryForRecovery([filter], destination: .thread(root), phase: .head)
                try Task.checkCancellation()
                let ingested = try await store.ingest(batch: events, phase: .backfill)
                guard ingested.rejected.isEmpty else { throw ThreadLoadFailure.invalidResponse }
                try Task.checkCancellation()
                if events.count < limit { try await store.recordThreadFetch(root: root) }
                try Task.checkCancellation()
                completeThreadLoad(root, token: token, result: .success(events))
                return
            } catch {
                guard !Task.isCancelled, threadLoading.requests[root]?.token == token else { return }
                let failure = ThreadLoadFailure.classify(error)
                if failure.isRetryable, attempt < 2, threadLoading.connectionIsReady {
                    // No request permit is held during the backoff. Rate-limit hints
                    // are additionally honoured by SubscriptionManager's shared gate.
                    do { try await sleepFor(.seconds(Double(attempt + 1))) } catch { return }
                    continue
                }
                Self.threadLoadLog.error("Thread load failed: \(String(describing: failure), privacy: .public)")
                completeThreadLoad(root, token: token, result: .failure(failure))
                return
            }
        }
    }

    private func completeThreadLoad(_ root: String, token: UUID, result: Result<[NostrEvent], Error>) {
        guard let request = threadLoading.requests[root], request.token == token else { return }
        request.task = nil
        switch result {
        case .success: setThreadState(.loaded, request: request)
        case let .failure(error): setThreadState(.failed(.classify(error)), request: request)
        }
        finishThreadWaiters(request, result: result)
        discardUnobservedThread(root, request: request)
    }

    private func setThreadState(_ state: ThreadLoadState, request: ThreadLoadContext.Request) {
        guard request.state != state else { return }
        request.state = state
        for observer in request.observers.values {
            observer.yield(state)
        }
    }

    private func finishThreadWaiters(
        _ request: ThreadLoadContext.Request, result: Result<[NostrEvent], Error>
    ) {
        let waiters = request.waiters.values
        request.waiters.removeAll()
        for waiter in waiters {
            waiter.resume(with: result)
        }
    }

    private func cancelThreadWaiter(root: String, id: UUID) {
        guard let request = threadLoading.requests[root] else { return }
        request.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
        discardUnobservedThread(root, request: request)
    }

    private func removeThreadObserver(root: String, id: UUID) {
        guard let request = threadLoading.requests[root] else { return }
        request.observers.removeValue(forKey: id)
        discardUnobservedThread(root, request: request)
    }

    private func discardUnobservedThread(_ root: String, request: ThreadLoadContext.Request) {
        guard request.observers.isEmpty, request.waiters.isEmpty else { return }
        request.task?.cancel()
        threadLoading.requests.removeValue(forKey: root)
    }

    private static let threadLoadLog = Logger(subsystem: "Hive", category: "ThreadLoading")
}
