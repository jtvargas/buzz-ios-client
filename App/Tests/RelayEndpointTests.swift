import Foundation
@testable import Hive
import Testing

/// The relay endpoint's two jobs: accept what an owner can plausibly paste, and never
/// prefill an address that cannot connect.
@Suite("Relay endpoint", .timeLimit(.minutes(1)))
struct RelayEndpointTests {
    /// Nothing is prefilled: the relay belongs to whoever runs it, and the constant that used
    /// to live here put one person's tailnet host on every fresh install's first screen. An
    /// unset device reads as empty, and empty is not a usable address — which is what opens
    /// the editor rather than leaving a required field folded away.
    @Test("an unset device prefills no relay at all")
    func prefillsNothing() {
        let previousRelay = RelayEndpoint.storedURLString
        defer { RelayEndpoint.storedURLString = previousRelay }

        UserDefaults.standard.removeObject(forKey: "relay.websocketURL")
        #expect(RelayEndpoint.storedURLString.isEmpty)
        #expect(RelayEndpoint.websocketURL(from: RelayEndpoint.storedURLString) == nil)
    }

    @Test("accepts ws and wss, and rejects anything that is not a websocket URL")
    func acceptsWebsocketSchemes() {
        #expect(RelayEndpoint.websocketURL(from: "wss://hive.example.ts.net") != nil)
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
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "https://hive.example.ts.net")
            == "wss://hive.example.ts.net")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "http://10.0.0.2:3004")
            == "ws://10.0.0.2:3004")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "wss://hive.example.ts.net")
            == "wss://hive.example.ts.net")
        #expect(RelayEndpoint.websocketURLString(fromAnyRelay: "ftp://relay.example") == nil)
    }

    /// The NIP-CW window client pages against the HTTP form of whatever socket is in use.
    @Test("derives the HTTP query endpoint from the socket URL")
    func derivesQueryURL() throws {
        let secure = try #require(RelayEndpoint.websocketURL(from: "wss://hive.example.ts.net"))
        #expect(RelayEndpoint.queryURL(for: secure)?.absoluteString
            == "https://hive.example.ts.net/query")
        let plain = try #require(RelayEndpoint.websocketURL(from: "ws://10.0.0.2:3004"))
        #expect(RelayEndpoint.queryURL(for: plain)?.absoluteString == "http://10.0.0.2:3004/query")
    }

    /// The blob store hangs off the relay's HTTP root — the upload client appends
    /// its own path components, so this must be the bare base and not `/query`'s
    /// parent by coincidence.
    @Test("derives the HTTP base the blob store hangs off")
    func derivesHTTPBase() throws {
        let secure = try #require(RelayEndpoint.websocketURL(from: "wss://hive.example.ts.net"))
        #expect(RelayEndpoint.httpBaseURL(for: secure)?.absoluteString
            == "https://hive.example.ts.net")
        let plain = try #require(RelayEndpoint.websocketURL(from: "ws://10.0.0.2:3004"))
        #expect(RelayEndpoint.httpBaseURL(for: plain)?.absoluteString == "http://10.0.0.2:3004")
        // What the upload client actually PUTs to, once it has appended its path.
        #expect(RelayEndpoint.httpBaseURL(for: secure)?.appendingPathComponent("upload").absoluteString
            == "https://hive.example.ts.net/upload")
    }
}
