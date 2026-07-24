import Foundation
@testable import NostrCore
import Testing

@Suite("RelayConnection query and publish")
struct RelayConnectionQueryPublishTests {
    // MARK: - Query send-failure (the leak fix)

    @Test(
        "A query whose REQ fails to send resumes the caller immediately with an error",
        .timeLimit(.minutes(1))
    )
    func querySendFailureResumesImmediately() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // The REQ cannot go out. With the query deadline set an hour away, only
        // an immediate resume — not a watchdog — can end this call promptly.
        await relay.failSends(with: .sendFailed("broken pipe"))
        await #expect(throws: RelayConnectionError.connectionLost) {
            _ = try await connection.query([Filter(kinds: [.channelMessage])])
        }

        await connection.stop()
    }

    // MARK: - CLOSED auth-required retry-once

    @Test("A CLOSED auth-required re-authenticates and retries the query once")
    func closedAuthRequiredRetriesOnce() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, challenge: "c1", authSendIndex: 0)

        let queryTask = Task { try await connection.query([Filter(kinds: [.channelMessage])]) }
        let firstReq = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: firstReq)

        // The relay forgot our auth and closes the subscription for it.
        await relay.enqueue(Frames.closed(subscriptionID, "auth-required: re-authenticate"))
        // It re-challenges; the connection answers and retries the same sub.
        await relay.enqueue(Frames.challenge("c2"))
        let secondAnswer = await relay.awaitSend(index: 2)
        let secondAuthID = try authEventID(from: secondAnswer)
        await relay.enqueue(Frames.ok(secondAuthID, true))

        let retriedReq = await relay.awaitSend(index: 3)
        #expect(try reqSubscriptionID(from: retriedReq) == subscriptionID)

        let event = try await signer.sign(kind: .channelMessage, content: "after re-auth")
        await relay.enqueue(Frames.event(subscriptionID, event))
        await relay.enqueue(Frames.eose(subscriptionID))

        let events = try await queryTask.value
        #expect(events == [event])

        await connection.stop()
    }

    @Test("A second CLOSED auth-required is not retried; the query fails")
    func closedAuthRequiredRetriesOnlyOnce() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, challenge: "c1", authSendIndex: 0)

        let queryTask = Task { try await connection.query([Filter(kinds: [.channelMessage])]) }
        let firstReq = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: firstReq)

        await relay.enqueue(Frames.closed(subscriptionID, "auth-required: once"))
        await relay.enqueue(Frames.challenge("c2"))
        let secondAnswer = await relay.awaitSend(index: 2)
        let secondAuthID = try authEventID(from: secondAnswer)
        await relay.enqueue(Frames.ok(secondAuthID, true))
        _ = await relay.awaitSend(index: 3) // the one retry

        // A second auth-required close has exhausted the single retry.
        await relay.enqueue(Frames.closed(subscriptionID, "auth-required: again"))
        await #expect(throws: RelayConnectionError.subscriptionClosed(.authRequired("again"))) {
            _ = try await queryTask.value
        }

        await connection.stop()
    }

    // MARK: - CLOSED restricted (no retry)

    @Test("A CLOSED restricted surfaces immediately and is never retried")
    func closedRestrictedDoesNotRetry() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let queryTask = Task { try await connection.query([Filter(kinds: [.channelMessage])]) }
        let firstReq = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: firstReq)

        await relay.enqueue(Frames.closed(subscriptionID, "restricted: not a member"))
        await #expect(throws: RelayConnectionError.subscriptionClosed(.restricted("not a member"))) {
            _ = try await queryTask.value
        }

        // No re-auth was attempted: the only sends are the auth answer and the
        // single REQ.
        #expect(await relay.sentFrames.count == 2)

        await connection.stop()
    }

    // MARK: - Mid-backfill drop

    @Test("A disconnect mid-backfill throws and never returns the partial set as complete")
    func midBackfillDropThrows() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let queryTask = Task { try await connection.query([Filter(kinds: [.channelMessage])]) }
        let firstReq = await relay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: firstReq)

        // A partial delivery, then the socket drops before EOSE.
        let partial = try await signer.sign(kind: .channelMessage, content: "partial-1")
        await relay.enqueue(Frames.event(subscriptionID, partial))
        await relay.enqueueFailure(.receiveFailed("socket dropped mid-backfill"))

        // The query throws rather than returning `[partial]` as if it were the
        // complete answer; no EOSE was fabricated.
        await #expect(throws: RelayConnectionError.connectionLost) {
            _ = try await queryTask.value
        }

        await connection.stop()
    }

    // MARK: - Publish

    @Test("A published event resolves on an accepting OK")
    func publishAccepted() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "ship it")
        let publishTask = Task { try await connection.publish(event) }

        let eventFrame = await relay.awaitSend(index: 1)
        #expect(try publishedEventID(from: eventFrame) == event.id)
        await relay.enqueue(Frames.ok(event.id, true))

        try await publishTask.value
        await connection.stop()
    }

    @Test("A duplicate rejection is treated as a successful publish")
    func publishDuplicateIsSuccess() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "dup")
        let publishTask = Task { try await connection.publish(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, false, "duplicate: already stored"))

        try await publishTask.value // resolves without throwing
        await connection.stop()
    }

    @Test("A terminal rejection fails the publish with the classified reason")
    func publishRestrictedIsTerminal() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "no")
        let publishTask = Task { try await connection.publish(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, false, "restricted: not permitted"))

        await #expect(throws: RelayConnectionError.publishRejected(.restricted("not permitted"))) {
            _ = try await publishTask.value
        }
        await connection.stop()
    }

    @Test("A rate-limited rejection fails the publish, carrying the retryable reason")
    func publishRateLimitedCarriesReason() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "slow down")
        let publishTask = Task { try await connection.publish(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, false, "rate-limited: slow down"))

        await #expect(throws: RelayConnectionError.publishRejected(.rateLimited("slow down"))) {
            _ = try await publishTask.value
        }
        await connection.stop()
    }

    @Test("An in-flight publish fails when the socket drops before its OK")
    func inFlightPublishFailsOnDisconnect() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "in flight")
        let publishTask = Task { try await connection.publish(event) }
        _ = await relay.awaitSend(index: 1) // EVENT is on the wire, OK not yet back
        await relay.enqueueFailure(.connectionClosed)

        await #expect(throws: RelayConnectionError.connectionLost) {
            _ = try await publishTask.value
        }
        await connection.stop()
    }

    @Test("A second publish of an already-pending event id is refused, not silently stranded")
    func duplicateInFlightPublishIsRefused() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "once")
        let firstPublish = Task { try await connection.publish(event) }
        _ = await relay.awaitSend(index: 1) // first EVENT on the wire, OK pending

        await #expect(throws: RelayConnectionError.duplicatePublish) {
            try await connection.publish(event)
        }

        // The refusal must not have disturbed the first caller.
        await relay.enqueue(Frames.ok(event.id, true))
        try await firstPublish.value
        await connection.stop()
    }

    @Test("A publish whose OK never arrives times out instead of hanging forever")
    func publishTimesOutWithoutOK() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        var config = inertConfig()
        config.publishTimeout = .milliseconds(80)
        let connection = makeInertConnection(signer: signer, transports: transports, config: config)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .channelMessage, content: "never acknowledged")
        // The relay stays live (subscription traffic could keep the watchdog
        // satisfied) but simply never sends the OK.
        await #expect(throws: RelayConnectionError.timedOut) {
            try await connection.publish(event)
        }
        await connection.stop()
    }

    @Test("An auth-required retry whose query already failed does not resend a zombie REQ")
    func closedRetryAfterDropDoesNotResendREQ() async throws {
        let signer = try InMemorySigner()
        let firstRelay = FakeRelay()
        let secondRelay = FakeRelay()
        let transports = TransportQueue([firstRelay, secondRelay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, firstRelay, challenge: "c1", authSendIndex: 0)

        let queryTask = Task { try await connection.query([Filter(kinds: [.channelMessage])]) }
        let reqFrame = await firstRelay.awaitSend(index: 1)
        let subscriptionID = try reqSubscriptionID(from: reqFrame)

        // The relay demands re-auth, then the socket drops before re-auth can
        // complete — failing the in-flight query.
        await firstRelay.enqueue(Frames.closed(subscriptionID, "auth-required: re-authenticate"))
        await firstRelay.enqueueFailure(.connectionClosed)
        await #expect(throws: RelayConnectionError.self) {
            _ = try await queryTask.value
        }

        // The reconnect authenticates on a fresh socket; the parked retry task
        // wakes, finds its query gone, and must stay silent.
        try await driveAuthToReady(connection, secondRelay, challenge: "c2", authSendIndex: 0)
        try await Task.sleep(for: .milliseconds(80)) // grace for any wrong resend to surface
        let framesAfterAuth = await secondRelay.sentFrames
        #expect(framesAfterAuth.count == 1, "only the AUTH answer belongs on the new socket")

        await connection.stop()
    }
}
