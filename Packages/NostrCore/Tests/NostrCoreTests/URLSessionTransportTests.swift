import Foundation
@testable import NostrCore
import Testing

@Suite("URLSessionTransport")
struct URLSessionTransportTests {
    // MARK: - Open timeout

    @Test(
        "connect() throws connectTimeout when the socket opens TCP but the handshake never completes",
        .timeLimit(.minutes(1))
    )
    func openTimeoutFires() async throws {
        // A loopback listener that accepts the TCP connection but never answers
        // the websocket upgrade — deterministic, no external network.
        let blackHole = try LoopbackBlackHole()
        defer { blackHole.stop() }

        let transport = URLSessionTransport(openTimeout: .milliseconds(400))
        let url = try #require(URL(string: "ws://127.0.0.1:\(blackHole.port)"))

        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: TransportError.connectTimeout) {
            try await transport.connect(url: url)
        }
        let elapsed = clock.now - start

        // The transport's own timeout resolved the connect, not an OS-level
        // stall: it fired promptly after the deadline rather than hanging.
        #expect(elapsed < .seconds(5))
    }

    @Test("A timed-out connect leaves the transport closed")
    func timedOutConnectIsClosed() async throws {
        let blackHole = try LoopbackBlackHole()
        defer { blackHole.stop() }

        let transport = URLSessionTransport(openTimeout: .milliseconds(300))
        let url = try #require(URL(string: "ws://127.0.0.1:\(blackHole.port)"))

        await #expect(throws: TransportError.connectTimeout) {
            try await transport.connect(url: url)
        }
        // The socket was torn down, so further I/O reports a closed connection.
        await #expect(throws: TransportError.connectionClosed) {
            _ = try await transport.receive()
        }
    }

    // MARK: - Operations before connect

    @Test("receive() before connect throws connectionClosed")
    func receiveBeforeConnect() async {
        let transport = URLSessionTransport()
        await #expect(throws: TransportError.connectionClosed) {
            _ = try await transport.receive()
        }
    }

    @Test("send() before connect throws connectionClosed")
    func sendBeforeConnect() async {
        let transport = URLSessionTransport()
        await #expect(throws: TransportError.connectionClosed) {
            try await transport.send("frame")
        }
    }

    @Test("ping() before connect throws connectionClosed")
    func pingBeforeConnect() async {
        let transport = URLSessionTransport()
        await #expect(throws: TransportError.connectionClosed) {
            try await transport.ping()
        }
    }

    @Test("A fresh transport reports no inbound activity")
    func noActivityBeforeConnect() async {
        let transport = URLSessionTransport()
        #expect(await transport.lastReceivedAt() == nil)
        #expect(await transport.idleInterval() == nil)
    }

    @Test("close() before connect is a harmless no-op")
    func closeBeforeConnect() async {
        let transport = URLSessionTransport()
        await transport.close()
        await #expect(throws: TransportError.connectionClosed) {
            _ = try await transport.receive()
        }
    }
}
