import Foundation

/// A `URLProtocol` that serves avatar bytes from a per-host script, so the loader's
/// fetch strategy can be asserted without a network.
///
/// Scripts are keyed by *host* rather than by request header, because
/// `URLSession.data(from:)` sends no headers a test could smuggle a scenario id through,
/// and because giving every test its own host keeps parallel suites from sharing state
/// even though the registry itself is process-wide.
///
/// What a test learns from this that it cannot learn any other way: which URLs the loader
/// actually requested, and in what order. That is the whole of the thumbnail-preference
/// and single-shot-fallback contract, and the observable half of the negative cache.
final class StubAvatarProtocol: URLProtocol {
    /// The host suffix this claims. Anything else is left to the real loading system, so
    /// registering the class on one session cannot affect another.
    static let hostSuffix = ".avatartest"

    private static let registry = Registry()

    /// Scripts `host` to answer the given paths with the given bytes, and everything else
    /// with a 404. Clears any previous script and recorded history for that host.
    static func register(host: String, responses: [String: Data]) {
        registry.register(host: host, responses: responses)
    }

    /// Every path requested against `host`, in order, including the ones that 404'd.
    static func requestedPaths(host: String) -> [String] {
        registry.requestedPaths(host: host)
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(hostSuffix) ?? false
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client else { return }
        guard let url = request.url, let host = url.host else {
            client.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let body = Self.registry.answer(host: host, path: url.path)
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: body == nil ? 404 : 200,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        ) else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotParseResponse))
            return
        }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // A 404 still carries a body on the real relay — JSON, which no image decoder can
        // read — so the stub sends one too. Answering a 404 with image bytes would hide
        // the status check the loader relies on.
        client.urlProtocol(self, didLoad: body ?? Data(#"{"error":"not_found"}"#.utf8))
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// The process-wide script and history, behind a lock.
    ///
    /// `@unchecked Sendable` because `URLProtocol` hands `startLoading()` to whichever
    /// thread the session picked, so the state genuinely is shared; the lock is what makes
    /// that safe, and it is the only thing being asserted here.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var responses: [String: [String: Data]] = [:]
        private var history: [String: [String]] = [:]

        func register(host: String, responses: [String: Data]) {
            lock.withLock {
                self.responses[host] = responses
                history[host] = []
            }
        }

        func requestedPaths(host: String) -> [String] {
            lock.withLock { history[host] ?? [] }
        }

        func answer(host: String, path: String) -> Data? {
            lock.withLock {
                history[host, default: []].append(path)
                return responses[host]?[path]
            }
        }
    }
}
