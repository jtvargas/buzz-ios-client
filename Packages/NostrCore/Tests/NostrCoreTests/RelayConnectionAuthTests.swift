import Foundation
@testable import NostrCore
import Testing

@Suite("RelayConnection NIP-42 handshake")
struct RelayConnectionAuthTests {
    private static let url = URL(string: "wss://relay.example.com")!

    private func makeConnection(
        signer: some EventSigner,
        transports: TransportQueue
    ) -> RelayConnection {
        RelayConnection(
            url: Self.url,
            signer: signer,
            config: inertConfig(),
            makeTransport: { await transports.next() },
            backoffSleep: { _ in }
        )
    }

    // MARK: - Happy path

    @Test(
        "connect → challenge → auth OK → ready; a query issued before ready waits, then its frames route",
        .timeLimit(.minutes(1))
    )
    func happyPathQueryWaitsForAuth() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()

        // Issued before authentication: the REQ must not go out until ready.
        async let queried = connection.query([Filter(kinds: [.channelMessage])])

        await relay.enqueue(Frames.challenge("c1"))
        // The AUTH answer is the first thing the client sends — before any REQ.
        let authFrame = await relay.awaitSend(index: 0)
        let authID = try authEventID(from: authFrame)
        await relay.enqueue(Frames.ok(authID, true))

        // Only after ready does the queued REQ reach the wire.
        let reqFrame = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: reqFrame)

        let event = try await signer.sign(kind: .channelMessage, content: "hello")
        await relay.enqueue(Frames.event(subscriptionID, event))
        await relay.enqueue(Frames.eose(subscriptionID))

        let events = try await queried
        #expect(events == [event])
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    // MARK: - Auth tags

    @Test("The auth answer carries exactly the NIP-42 relay and challenge tags")
    func authAnswerTagShape() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()
        await relay.enqueue(Frames.challenge("the-challenge-token"))
        let authFrame = await relay.awaitSend(index: 0)

        let message = try JSONDecoder().decode(ClientMessage.self, from: Data(authFrame.utf8))
        guard case let .auth(event) = message else {
            Issue.record("expected an AUTH frame, got \(authFrame)")
            return
        }

        #expect(event.kind == .clientAuthentication)
        #expect(event.content.isEmpty)
        #expect(event.tags == [
            ["relay", Self.url.absoluteString],
            ["challenge", "the-challenge-token"],
        ])
        #expect(event.isValid)

        await connection.stop()
    }

    // MARK: - Auth races

    @Test("Unrelated frames interleaved around the auth OK do not disturb a queued request")
    func authRaceInterleavedFrames() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()
        async let queried = connection.query([Filter(kinds: [.channelMessage])])

        await relay.enqueue(Frames.challenge("c1"))
        let authFrame = await relay.awaitSend(index: 0)
        let authID = try authEventID(from: authFrame)

        // A NOTICE lands between the challenge and the accepting OK.
        await relay.enqueue(#"["NOTICE","just so you know"]"#)
        await relay.enqueue(Frames.ok(authID, true))

        let reqFrame = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: reqFrame)

        let event = try await signer.sign(kind: .channelMessage, content: "routed")
        await relay.enqueue(Frames.event(subscriptionID, event))
        await relay.enqueue(Frames.eose(subscriptionID))

        let events = try await queried
        #expect(events == [event])

        // The REQ was sent exactly once: index 2 is the CLOSE that follows EOSE,
        // not a duplicate REQ.
        let closeFrame = await relay.awaitSend(index: 2)
        #expect(closeFrame.hasPrefix(#"["CLOSE""#))

        await connection.stop()
    }

    @Test("A second challenge supersedes the first; the answer to the latest one completes auth")
    func doubleChallenge() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()

        await relay.enqueue(Frames.challenge("first"))
        let firstAnswer = await relay.awaitSend(index: 0)
        let firstID = try authEventID(from: firstAnswer)

        await relay.enqueue(Frames.challenge("second"))
        let secondAnswer = await relay.awaitSend(index: 1)
        let secondID = try authEventID(from: secondAnswer)

        // Distinct challenges yield distinct answers.
        #expect(firstID != secondID)

        // An OK for the superseded first answer is ignored — only the latest
        // answer's OK moves the connection to ready.
        await relay.enqueue(Frames.ok(firstID, true))
        await relay.enqueue(Frames.ok(secondID, true))

        await waitForState(connection) { $0 == .ready }
        #expect(await connection.state == .ready)

        await connection.stop()
    }

    // MARK: - Fail-fast on a recorded failure

    @Test(
        "After a transient auth failure a later request fails fast rather than suspending",
        .timeLimit(.minutes(1))
    )
    func memoizedFailureFailsFast() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()
        await relay.enqueue(Frames.challenge("c1"))
        let authFrame = await relay.awaitSend(index: 0)
        let authID = try authEventID(from: authFrame)
        // A retryable reason is a transient auth failure, not a terminal rejection.
        await relay.enqueue(Frames.ok(authID, false, "error: try again"))

        // Wait until the failure is memoized, so the query below is the
        // late-arriver case the memoization exists for.
        await waitUntil { await connection.currentAuthFailure != nil }

        // With the auth watchdog set an hour out, only the memoized failure can
        // resolve this promptly.
        await #expect(throws: RelayConnectionError.self) {
            _ = try await connection.query([Filter(kinds: [.channelMessage])])
        }

        await connection.stop()
    }

    // MARK: - Terminal rejection

    @Test("A terminal auth rejection stops the connection and never reconnects")
    func terminalAuthRejection() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeConnection(signer: signer, transports: transports)

        try await connection.connect()
        await relay.enqueue(Frames.challenge("c1"))
        let authFrame = await relay.awaitSend(index: 0)
        let authID = try authEventID(from: authFrame)
        await relay.enqueue(Frames.ok(authID, false, "restricted: identity not permitted"))

        await waitForState(connection) {
            if case .stopped(.authRejected) = $0 { return true }
            return false
        }
        #expect(await connection.state == .stopped(.authRejected(reason: "restricted: identity not permitted")))

        // The rejected identity is never retried: only the initial socket was
        // ever vended.
        #expect(await transports.vendedCount == 1)

        // Further requests fail fast with the rejection.
        let event = try await signer.sign(kind: .channelMessage, content: "x")
        await #expect(throws: RelayConnectionError.authenticationRejected("restricted: identity not permitted")) {
            try await connection.publish(event)
        }
    }
}
