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

    // MARK: - The first frame a relay sends

    @Test(
        "A relay that stays silent until spoken to still has its first frame delivered",
        .timeLimit(.minutes(1))
    )
    func silentRelayFirstFrameIsDelivered() async throws {
        // `relay.damus.io` and `nos.lol` are this shape: nothing on connect, so
        // the open probe is settled by its pong and the read it armed outlives
        // it — holding the queue position the relay's first frame lands in.
        let server = try LoopbackWebSocketServer(greeting: nil, replies: ["[\"EOSE\",\"sub\"]"])
        defer { server.stop() }

        let transport = URLSessionTransport()
        try await transport.connect(url: try #require(server.url))
        try await transport.send("[\"REQ\",\"sub\",{}]")

        let frame = await firstFrame(from: transport, within: .seconds(5))
        #expect(frame == "[\"EOSE\",\"sub\"]")
        await transport.close()
    }

    @Test("A relay that greets on connect has its greeting delivered first", .timeLimit(.minutes(1)))
    func greetingRelayKeepsFrameOrder() async throws {
        // A Buzz relay is this shape: its NIP-42 challenge arrives unprompted and
        // doubles as the proof the socket is open.
        let server = try LoopbackWebSocketServer(
            greeting: "[\"AUTH\",\"challenge\"]",
            replies: ["[\"EOSE\",\"sub\"]"]
        )
        defer { server.stop() }

        let transport = URLSessionTransport()
        try await transport.connect(url: try #require(server.url))

        #expect(await firstFrame(from: transport, within: .seconds(5)) == "[\"AUTH\",\"challenge\"]")
        try await transport.send("[\"REQ\",\"sub\",{}]")
        #expect(await firstFrame(from: transport, within: .seconds(5)) == "[\"EOSE\",\"sub\"]")
        await transport.close()
    }

    /// `receive()` bounded by a deadline, so a transport that never delivers
    /// fails in seconds with a legible `nil` rather than hanging the suite.
    ///
    /// The deadline closes the socket rather than merely giving up: `receive()`
    /// is not cancellable, so an abandoned one would keep the task group open
    /// for ever — which is a hang, not a failure. Closing completes the pending
    /// read with an error, which is what lets the reader finish.
    private func firstFrame(from transport: URLSessionTransport, within deadline: Duration) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await transport.receive() }
            group.addTask {
                // A cancelled sleep means the reader won — leave the socket alone.
                do { try await Task.sleep(for: deadline) } catch { return nil }
                await transport.close()
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
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
