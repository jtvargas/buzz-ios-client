import Foundation
import NostrCore

/// The NIP-CW window client: issues a `POST /query` window request over the
/// injected ``HTTPTransport`` and classifies the response into a ``WindowResult``.
///
/// It rides the `HTTPTransport` seam and nothing else — BuzzKit never touches
/// `URLSession`, so this whole path is deterministic under a scripted transport in
/// tests. Each request is authenticated per NIP-98: a fresh signed `Authorization`
/// header is minted for the exact URL, method, and body being sent, so two
/// otherwise-identical requests carry distinct, non-replayable headers.
///
/// The client is stateless and touches no storage. It parses and validates one
/// response and hands back a typed result; advancing watermarks, ingesting rows,
/// caching summaries, and falling back on degradation are all the engine's job
/// (step 6). The client performs no fallback of its own.
///
/// # Trust profile
///
/// This runs under NIP-CW's **authenticated-transport** profile (ADR-0003): TLS to
/// the deliberately-configured relay is the response-origin authority, so the
/// MUST-level structural checks — exactly one bounds overlay, request-cursor
/// binding, parseable content, `has_more`/`next_cursor` agreement — are enforced,
/// while overlay signature verification is not. The rows and aux events are
/// ordinary signed events and are verified where they always are: the store's
/// ingest choke point, one layer up.
public struct WindowClient: Sendable {
    private let transport: any HTTPTransport
    private let queryURL: URL
    private let signer: any EventSigner

    /// - Parameters:
    ///   - transport: the HTTP seam the request rides; a scripted fake in tests,
    ///     `URLSessionHTTPTransport` in production.
    ///   - queryURL: the relay's NIP-98-authenticated `POST /query` endpoint.
    ///   - signer: the identity each request's NIP-98 header is attributed to.
    public init(transport: any HTTPTransport, queryURL: URL, signer: some EventSigner) {
        self.transport = transport
        self.queryURL = queryURL
        self.signer = signer
    }

    /// Fetches one window page and classifies the outcome.
    ///
    /// - Returns: ``WindowResult/page(_:)`` for a valid page, ``WindowResult/invalidPage(_:)``
    ///   for a malformed-but-retryable page, or ``WindowResult/degraded(_:)`` when
    ///   the fast path is unavailable (transport failure, non-2xx status, an
    ///   unreadable body, or no bounds overlay).
    /// - Throws: only when the request could not be *formed* — a signer or encoder
    ///   failure. A failure to *complete* the request is a ``WindowResult/degraded(_:)``
    ///   outcome, not a throw, so the engine's fallback path is data, not an error
    ///   channel. A cancellation propagates.
    public func fetch(_ filter: WindowFilter) async throws -> WindowResult {
        let body = try filter.encodedRequestBody()

        // A fresh NIP-98 header per request: a new nonce means a new event id, so a
        // captured header cannot be replayed and two successive fetches never carry
        // the same Authorization value.
        let authorization = try await NIP98.authorizationHeader(
            url: queryURL,
            method: "POST",
            body: body,
            signer: signer
        )
        let headers = [
            "Content-Type": "application/json",
            "Authorization": authorization,
        ]

        let response: (body: Data, status: Int)
        do {
            response = try await transport.post(body: body, to: queryURL, headers: headers)
        } catch let error as TransportError {
            // The round-trip never completed — the §Degradation "error response"
            // signal. Fall back, don't throw.
            return .degraded(.transportFailure(error))
        }

        guard (200 ... 299).contains(response.status) else {
            // A non-2xx is a completed exchange the caller interprets; here a
            // rejected or unsupported filter is a downgrade signal.
            return .degraded(.httpStatus(response.status))
        }

        guard let events = try? JSONDecoder().decode([NostrEvent].self, from: response.body) else {
            return .degraded(.unreadableResponse)
        }

        return WindowResponseParser.classify(events, for: filter)
    }
}
