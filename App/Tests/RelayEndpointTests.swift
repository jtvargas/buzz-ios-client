import Foundation
@testable import Hive
import Testing

/// The relay endpoint's two jobs: accept what an owner can plausibly paste, and never
/// prefill an address that cannot connect.
@Suite("Relay endpoint", .timeLimit(.minutes(1)))
struct RelayEndpointTests {
    /// The prefill is the one address a fresh install will actually try, and the URL is
    /// only editable during onboarding — so a default that cannot connect strands the
    /// install with no way back. The plaintext tailnet port it used to name refuses the
    /// WebSocket handshake now, so the default must be the TLS endpoint.
    @Test("the prefilled relay is a valid wss endpoint")
    func defaultIsSecureWebsocket() throws {
        let url = try #require(RelayEndpoint.websocketURL(from: RelayEndpoint.defaultURLString))
        #expect(url.scheme == "wss")
        #expect(url.host?.isEmpty == false)
        #expect(!RelayEndpoint.defaultURLString.contains(":3004"))
    }

    @Test("accepts ws and wss, and rejects anything that is not a websocket URL")
    func acceptsWebsocketSchemes() {
        #expect(RelayEndpoint.websocketURL(from: "wss://homelab.tail4bc643.ts.net") != nil)
        #expect(RelayEndpoint.websocketURL(from: " wss://relay.example  ") != nil)
        #expect(RelayEndpoint.websocketURL(from: "ws://192.168.1.10:3004") != nil)
        #expect(RelayEndpoint.websocketURL(from: "https://relay.example") == nil)
        #expect(RelayEndpoint.websocketURL(from: "wss://") == nil)
        #expect(RelayEndpoint.websocketURL(from: "not a url") == nil)
    }

    /// The desktop's pairing payload carries the relay's *HTTP* base, so the importer has
    /// to invert it — while a pasted `wss://` passes through untouched, which is the form
    /// the owner actually uses.
    @Test("normalises an HTTP relay base into a websocket URL, passing sockets through")
    func normalisesAnyRelayForm() {
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "https://homelab.tail4bc643.ts.net")
            == "wss://homelab.tail4bc643.ts.net")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "http://10.0.0.2:3004")
            == "ws://10.0.0.2:3004")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "wss://homelab.tail4bc643.ts.net")
            == "wss://homelab.tail4bc643.ts.net")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "ftp://relay.example") == nil)
    }

    /// The NIP-CW window client pages against the HTTP form of whatever socket is in use.
    @Test("derives the HTTP query endpoint from the socket URL")
    func derivesQueryURL() throws {
        let secure = try #require(RelayEndpoint.websocketURL(from: "wss://homelab.tail4bc643.ts.net"))
        #expect(RelayEndpoint.queryURL(for: secure)?.absoluteString
            == "https://homelab.tail4bc643.ts.net/query")
        let plain = try #require(RelayEndpoint.websocketURL(from: "ws://10.0.0.2:3004"))
        #expect(RelayEndpoint.queryURL(for: plain)?.absoluteString == "http://10.0.0.2:3004/query")
    }
}
