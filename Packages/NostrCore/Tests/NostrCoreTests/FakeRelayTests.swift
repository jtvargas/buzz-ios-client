import Foundation
@testable import NostrCore
import Testing

@Suite("FakeRelay scripted-transport contract")
struct FakeRelayTests {
    private let url = URL(string: "wss://relay.example.com")!

    // MARK: - Frame delivery

    @Test("Scripted frames arrive in order, one per receive() call")
    func framesArriveInOrder() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.enqueue([#"["EOSE","a"]"#, #"["EOSE","b"]"#, #"["EOSE","c"]"#])

        #expect(try await relay.receive() == #"["EOSE","a"]"#)
        #expect(try await relay.receive() == #"["EOSE","b"]"#)
        #expect(try await relay.receive() == #"["EOSE","c"]"#)
    }

    @Test("A receive parked before its frame is scripted resolves to that one frame")
    func pullBasedDelivery() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)

        // Park a read with nothing scripted yet, then hand it exactly one frame.
        // Whichever order the runtime interleaves these, the outcome is fixed.
        async let received = relay.receive()
        await relay.enqueue("frame-1")

        #expect(try await received == "frame-1")
        // The single scripted frame was consumed; nothing else was invented.
        #expect(await relay.pendingCount == 0)
    }

    @Test("Nothing is buffered beyond the script")
    func noBufferingBeyondScript() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.enqueue(["one", "two"])

        #expect(await relay.pendingCount == 2)
        _ = try await relay.receive()
        #expect(await relay.pendingCount == 1)
        _ = try await relay.receive()
        #expect(await relay.pendingCount == 0)
    }

    // MARK: - Send recording

    @Test("Successful sends are recorded in order")
    func recordsSends() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        try await relay.send(#"["REQ","s",{"kinds":[9]}]"#)
        try await relay.send(Data(#"["CLOSE","s"]"#.utf8))

        #expect(await relay.sentFrames == [#"["REQ","s",{"kinds":[9]}]"#, #"["CLOSE","s"]"#])
    }

    @Test("connect() records every attempted URL")
    func recordsConnectAttempts() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        try await relay.connect(url: url)
        #expect(await relay.connectAttempts == [url, url])
    }

    // MARK: - Scripted failures

    @Test("A connect-failure script throws on connect()")
    func connectFailureThrows() async throws {
        let relay = FakeRelay()
        await relay.failConnect(with: .connectFailed("refused"))
        await #expect(throws: TransportError.connectFailed("refused")) {
            try await relay.connect(url: url)
        }
    }

    @Test("A scripted send failure throws and records nothing")
    func sendFailureThrows() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.failSends(with: .sendFailed("broken pipe"))

        await #expect(throws: TransportError.sendFailed("broken pipe")) {
            try await relay.send("dropped")
        }
        #expect(await relay.sentFrames.isEmpty)

        // Recovery lets subsequent sends through.
        await relay.recoverSends()
        try await relay.send("delivered")
        #expect(await relay.sentFrames == ["delivered"])
    }

    @Test("A scripted mid-stream disconnect makes receive() throw connectionClosed")
    func midStreamDisconnect() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.enqueue("event-1")
        await relay.enqueueFailure(.connectionClosed)

        #expect(try await relay.receive() == "event-1")
        await #expect(throws: TransportError.connectionClosed) {
            try await relay.receive()
        }
    }

    @Test("A read that hangs then errors resolves deterministically to that error")
    func receiveHangsThenErrors() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)

        // The read has nothing to deliver — it hangs — until the relay errors it.
        let received = Task { try await relay.receive() }
        await relay.enqueueFailure(.receiveFailed("read timeout"))

        await #expect(throws: TransportError.receiveFailed("read timeout")) {
            _ = try await received.value
        }
    }

    @Test("close() unblocks a parked receive with connectionClosed")
    func closeUnblocksReceive() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)

        let received = Task { try await relay.receive() }
        await relay.close()

        await #expect(throws: TransportError.connectionClosed) {
            _ = try await received.value
        }
    }

    @Test("A frame sent after close throws connectionClosed")
    func sendAfterCloseThrows() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.close()

        await #expect(throws: TransportError.connectionClosed) {
            try await relay.send("late")
        }
    }

    // MARK: - Liveness mechanics

    @Test("ping() is counted and marks inbound activity")
    func pingRecorded() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        #expect(await relay.lastReceivedAt() == nil)

        try await relay.ping()

        #expect(await relay.pingCount == 1)
        #expect(await relay.lastReceivedAt() != nil)
        #expect(await relay.idleInterval() != nil)
    }

    @Test("A received frame marks inbound activity")
    func receiveMarksActivity() async throws {
        let relay = FakeRelay()
        try await relay.connect(url: url)
        await relay.enqueue("frame")
        _ = try await relay.receive()
        #expect(await relay.lastReceivedAt() != nil)
    }
}
