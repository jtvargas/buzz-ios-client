import Foundation
@testable import NostrCore
import Testing

@Suite("URLSessionHTTPTransport")
struct URLSessionHTTPTransportTests {
    private let url = URL(string: "https://relay.example.com/query")!

    /// A transport whose session serves every request from ``StubURLProtocol`` —
    /// no request touches the network, so the mapping is deterministic.
    private func makeTransport() -> URLSessionHTTPTransport {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSessionHTTPTransport(session: URLSession(configuration: config))
    }

    @Test("A 2xx exchange returns the response body and status, over a POST")
    func returnsBodyAndStatus() async throws {
        let transport = makeTransport()

        let (data, status) = try await transport.post(body: Data(), to: url, headers: [:])

        #expect(status == 200)
        // The stub echoes the method it observed, proving URLSession issued a POST.
        let payload = try JSONDecoder().decode([String: String].self, from: data)
        #expect(payload["method"] == "POST")
    }

    @Test("Caller headers reach the request verbatim")
    func forwardsHeaders() async throws {
        let transport = makeTransport()

        let (data, _) = try await transport.post(body: Data(), to: url, headers: ["X-Echo": "Nostr-token"])

        let payload = try JSONDecoder().decode([String: String].self, from: data)
        #expect(payload["echo"] == "Nostr-token")
    }

    @Test("A non-2xx status is returned, not thrown")
    func nonSuccessStatusIsReturned() async throws {
        let transport = makeTransport()

        let (_, status) = try await transport.post(body: Data(), to: url, headers: ["X-Stub-Status": "503"])

        #expect(status == 503)
    }

    @Test("A transport-level failure surfaces as requestFailed")
    func networkFailureMapsToRequestFailed() async throws {
        let transport = makeTransport()

        do {
            _ = try await transport.post(body: Data(), to: url, headers: ["X-Stub-Fail": "1"])
            Issue.record("post should have thrown on a network failure")
        } catch let error as TransportError {
            guard case .requestFailed = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
        }
    }
}

/// A `URLProtocol` that answers from instructions carried in the request's own
/// headers, so no shared mutable state couples parallel tests. It never touches
/// the network: every request is served locally and deterministically.
///
/// Control headers (all optional):
/// - `X-Stub-Fail`: any value ⇒ fail the request with a network error.
/// - `X-Stub-Status`: the HTTP status to answer with (default `200`).
/// - `X-Echo`: a value echoed back in the response body's `echo` field.
///
/// The response body is JSON `{"method": <verb>, "echo": <X-Echo>}`, which lets a
/// test assert the verb URLSession sent and that caller headers were forwarded.
final class StubURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }

        if request.value(forHTTPHeaderField: "X-Stub-Fail") != nil {
            client.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }

        guard let url = request.url else {
            client.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let status = request.value(forHTTPHeaderField: "X-Stub-Status").flatMap(Int.init) ?? 200
        let payload = [
            "method": request.httpMethod ?? "",
            "echo": request.value(forHTTPHeaderField: "X-Echo") ?? "",
        ]
        let body = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
