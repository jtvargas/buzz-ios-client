import Foundation
import NostrCore

/// A request's outcome, independent of whether its answer added any new database rows.
public enum ThreadLoadState: Hashable, Sendable {
    case idle
    case waitingForConnection
    case loading
    case loaded
    case failed(ThreadLoadFailure)

    public var isLoading: Bool {
        self == .loading || self == .waitingForConnection
    }

    public var failure: ThreadLoadFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }
}

public enum ThreadLoadFailure: Error, Hashable, Sendable {
    case connection
    case timeout
    case accessDenied
    case relay
    case storage
    case invalidResponse

    var isRetryable: Bool {
        self == .connection || self == .timeout || self == .relay
    }

    static func classify(_ error: any Error) -> Self {
        if let failure = error as? Self { return failure }
        guard let error = error as? RelayConnectionError else { return .storage }
        switch error {
        case .notConnected, .stopped, .connectionLost, .authenticationFailed:
            return .connection
        case .timedOut:
            return .timeout
        case .authenticationRejected:
            return .accessDenied
        case let .subscriptionClosed(reason), let .publishRejected(reason):
            return reason.disposition == .terminal ? .accessDenied : .relay
        case .duplicatePublish:
            return .relay
        }
    }
}

/// Accessed only by SyncEngine's actor. One task and one outcome per root, even when
/// a screen, a manual retry and reconnect recovery ask for the same thread together.
final class ThreadLoadContext {
    final class Request {
        var state: ThreadLoadState = .idle
        var token = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<[NostrEvent], Error>] = [:]
        var observers: [UUID: AsyncStream<ThreadLoadState>.Continuation] = [:]
    }

    var requests: [String: Request] = [:]
    var connectionIsReady = false
    var terminalFailure: ThreadLoadFailure?
}
