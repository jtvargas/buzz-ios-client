import Foundation

/// The production ``HTTPTransport`` over `URLSession`.
///
/// A thin, honest wrapper: it builds a POST `URLRequest`, applies the caller's
/// headers verbatim, and reports back the body and status `URLSession` returns.
/// It adds no default headers and interprets no status code — the seam is a dumb
/// pipe by contract, so an endpoint's `Content-Type`, `Authorization`, and its
/// reading of a 4xx/5xx all stay with the caller.
///
/// A value type over a `Sendable` `URLSession`, so an owner can hold and share it
/// freely across the concurrency domain.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    /// - Parameter session: the session to issue requests on; injectable for
    ///   tests (e.g. a `URLProtocol`-stubbed session) and for callers that need
    ///   their own configuration. Defaults to `.shared`.
    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(body: Data, to url: URL, headers: [String: String]) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // The round-trip never produced a response — DNS, TLS, a dropped
            // connection, a cancellation. Rendered to a string so the error stays
            // `Equatable` / `Sendable`, matching the rest of the taxonomy.
            throw TransportError.requestFailed(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            // `data(for:)` against an http(s) URL yields an `HTTPURLResponse`;
            // anything else means the exchange did not speak HTTP.
            throw TransportError.requestFailed("response was not an HTTP response")
        }
        return (data, http.statusCode)
    }
}
