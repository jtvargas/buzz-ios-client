import Foundation
import NostrCore

/// A scripted HTTP transport standing in for a real ``URLSessionHTTPTransport``,
/// copied from `NostrCoreTestSupport` per the repo's duplicate-the-harness
/// precedent rather than linked.
///
/// The copy is load-bearing, not laziness: `NostrCoreTestSupport` is a *static*
/// package product whose target depends on the `NostrCore` target, so linking it
/// into this test bundle embeds a second copy of NostrCore's object code beside
/// the dynamic package framework the host app already loads. Two copies of the
/// same Swift types make dynamic casts across them fail (`catch let error as
/// RelayConnectionError` stops matching), which silently broke the engine's
/// whole rejection path under test. One duplicated 100-line double is the cheap
/// side of that trade.
///
/// Determinism comes from continuations, never sleeps. A ``post(body:to:headers:)``
/// with nothing scripted parks on a continuation; a later ``enqueue(status:body:)``
/// or ``enqueueFailure(_:)`` resumes it, so a test's outcome never depends on
/// whether the script arrives before or after the caller.
actor FakeHTTPTransport: HTTPTransport {
    /// One request the client made, captured verbatim for assertion.
    struct RecordedRequest: Equatable, Sendable {
        let url: URL
        let body: Data
        let headers: [String: String]
    }

    /// One scripted outcome for a single ``post(body:to:headers:)``: a status and
    /// body, or a thrown transport error.
    private enum Outcome {
        case response(body: Data, status: Int)
        case failure(TransportError)
    }

    // MARK: Recorded interactions

    /// Every request the client made, in order.
    private(set) var requests: [RecordedRequest] = []

    // MARK: Scripted behaviour

    private var pending: [Outcome] = []
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    // MARK: - HTTPTransport

    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
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
    func enqueue(status: Int, body: Data) {
        deliver(.response(body: body, status: status))
    }

    /// Scripts a response whose body is `body`'s UTF-8 bytes.
    func enqueue(status: Int, body: String) {
        deliver(.response(body: Data(body.utf8), status: status))
    }

    /// Scripts a thrown transport error to end the next request — a network
    /// failure standing in for a dropped connection or an offline device.
    func enqueueFailure(_ error: TransportError) {
        deliver(.failure(error))
    }

    /// How many scripted outcomes are buffered and not yet consumed. A test can
    /// assert this is zero to prove nothing was scripted beyond what was used.
    var pendingCount: Int {
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
