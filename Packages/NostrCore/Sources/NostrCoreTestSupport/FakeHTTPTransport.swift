import Foundation
// Only NostrCore's public surface is used, so a plain import (not `@testable`)
// suffices — which is exactly what lets this double live in a shared support
// library both NostrCore's and BuzzKit's test targets can import.
import NostrCore

/// A scripted HTTP transport standing in for a real ``URLSessionHTTPTransport``.
///
/// The point of the ``HTTPTransport`` seam: layers that page a relay's HTTP query
/// bridge run against this with no network, no server, and no timing flakiness.
/// Tests script a response per request — a status and body, or a thrown transport
/// error — read back every request the client made (url, body, headers) for
/// assertion, and get determinism identical to `FakeRelay`.
///
/// Determinism comes from continuations, never sleeps. A ``post(body:to:headers:)``
/// with nothing scripted parks on a continuation; a later ``enqueue(status:body:)``
/// or ``enqueueFailure(_:)`` resumes it. Because there is one outcome per request,
/// the *result* of a test does not depend on whether the script arrives before or
/// after the caller — the same guarantee that makes multi-page reconcile scripts
/// (head page, then `next_cursor` follow-ups) deterministic.
///
/// This lives in ``NostrCoreTestSupport`` rather than any one test target so the
/// window-client tests in BuzzKit and the transport tests in NostrCore drive the
/// exact same double. The target ships no production code — it exists only to be
/// linked by test targets.
public actor FakeHTTPTransport: HTTPTransport {
    /// One request the client made, captured verbatim for assertion.
    public struct RecordedRequest: Equatable, Sendable {
        public let url: URL
        public let body: Data
        public let headers: [String: String]

        public init(url: URL, body: Data, headers: [String: String]) {
            self.url = url
            self.body = body
            self.headers = headers
        }
    }

    /// One scripted outcome for a single ``post(body:to:headers:)``: a status and
    /// body, or a thrown transport error.
    private enum Outcome {
        case response(body: Data, status: Int)
        case failure(TransportError)
    }

    // MARK: Recorded interactions

    /// Every request the client made, in order.
    public private(set) var requests: [RecordedRequest] = []

    // MARK: Scripted behaviour

    private var pending: [Outcome] = []
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    public init() {}

    // MARK: - HTTPTransport

    public func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        requests.append(RecordedRequest(url: url, body: body, headers: headers))
        switch await nextOutcome() {
        case let .response(body, status):
            return (body, status)
        case let .failure(error):
            throw error
        }
    }

    // MARK: - Test control

    /// Scripts a response — a status and body — for the next request.
    public func enqueue(status: Int, body: Data) {
        deliver(.response(body: body, status: status))
    }

    /// Scripts a response whose body is `body`'s UTF-8 bytes.
    public func enqueue(status: Int, body: String) {
        deliver(.response(body: Data(body.utf8), status: status))
    }

    /// Scripts a thrown transport error to end the next request — a network
    /// failure standing in for a dropped connection or an offline device.
    public func enqueueFailure(_ error: TransportError) {
        deliver(.failure(error))
    }

    /// How many scripted outcomes are buffered and not yet consumed. A test can
    /// assert this is zero to prove nothing was scripted beyond what was used.
    public var pendingCount: Int {
        pending.count
    }

    // MARK: - Internals

    /// The next scripted outcome, parking on a continuation if the script has not
    /// caught up to the request yet.
    private func nextOutcome() async -> Outcome {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands an outcome to the oldest parked request, or buffers it for the next
    /// one — the symmetric half of ``nextOutcome()``, so delivery order is fixed
    /// regardless of how request and script interleave.
    private func deliver(_ outcome: Outcome) {
        if waiters.isEmpty {
            pending.append(outcome)
        } else {
            waiters.removeFirst().resume(returning: outcome)
        }
    }
}
