import Foundation

/// A one-shot HTTP request/response reduced to the single operation the layers
/// above need, expressed as a testability seam.
///
/// # Why this exists
///
/// Some relay affordances ride HTTP rather than the websocket — the NIP-CW
/// `/query` pagination bridge most of all. Rather than let a higher layer reach
/// for `URLSession` directly (and become impossible to test without a network),
/// that round-trip is funnelled through this seam, exactly as the socket is
/// funnelled through ``RelayTransport``. The production path is
/// ``URLSessionHTTPTransport``; tests run against a scripted fake.
///
/// # Dumb, generic pipe
///
/// The transport moves opaque bytes to a URL under a caller-supplied header set
/// and returns opaque bytes with the HTTP status. It knows nothing of *what* it
/// carries: the request body is already-encoded `Data`, the response body comes
/// back undecoded, and the `Authorization` / `Content-Type` headers a particular
/// endpoint needs are the caller's to supply. This keeps NostrCore free of any
/// endpoint's semantics — the window-filter JSON of `/query`, its response
/// envelope, and its NIP-98 header all live one layer up, in BuzzKit.
///
/// # Status is data, not an error
///
/// A completed exchange returns its status code alongside the body; a non-2xx
/// response is a *result*, not a `throw`. The caller decides what a 404 or 401
/// means for its protocol. Only a round-trip that never yielded an HTTP response
/// at all — a network failure, or a response that did not speak HTTP — throws, as
/// ``TransportError/requestFailed(_:)``.
///
/// # `Sendable`, not `Actor`
///
/// Unlike the stateful websocket, each POST is independent and holds no
/// cross-call state to serialize, so the seam does not need `Actor` isolation —
/// only the guarantee that it can cross actor boundaries safely, since a
/// long-lived owner (a `SyncEngine` actor, in Phase 2) holds one.
public protocol HTTPTransport: Sendable {
    /// Performs a POST of `body` to `url` under `headers`.
    ///
    /// - Parameters:
    ///   - body: the already-encoded request body; sent verbatim.
    ///   - url: the endpoint to POST to.
    ///   - headers: header fields applied to the request as given. The transport
    ///     adds none of its own, so any `Content-Type` or `Authorization` an
    ///     endpoint requires belongs here.
    /// - Returns: the raw response body and the HTTP status code. A non-2xx
    ///   status is returned, not thrown — the caller interprets it.
    /// - Throws: ``TransportError/requestFailed(_:)`` if the request did not
    ///   complete with an HTTP response (a transport-level network failure, or a
    ///   response that was not HTTP).
    func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int)
}
