import Foundation
@testable import NostrCore
import Testing

/// ``RelayConnection/publishAwaitingResponse(_:timeout:)``: the same publish as
/// ``RelayConnection/publish(_:timeout:)``, with the relay's `OK` message text handed
/// back instead of dropped.
///
/// Buzz's *command* kinds carry their entire result in that field and never fan it out
/// as an event, so a caller that cannot read the message cannot learn the outcome. The
/// durable send path keeps its `Void` contract, which these tests hold alongside — the
/// existing publish suite proves that half.
@Suite("RelayConnection publish response", .timeLimit(.minutes(1)))
struct RelayConnectionPublishResponseTests {
    /// The shape the relay uses for a command answer: a literal prefix, then JSON.
    static let commandPayload = #"response:{"channel_id":"dm-01","created":true}"#

    @Test("an accepting OK hands back its message text verbatim")
    func acceptedReturnsMessage() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .directMessageOpen, content: "")
        let publishTask = Task { try await connection.publishAwaitingResponse(event) }
        _ = await relay.awaitSend(index: 1)

        // The payload is JSON nested inside a JSON string; the escaping frame builder
        // is what keeps it decodable on the way in.
        await relay.enqueue(Frames.okEncoding(event.id, true, Self.commandPayload))

        #expect(try await publishTask.value == Self.commandPayload)
        await connection.stop()
    }

    @Test("an accepting OK that says `duplicate` still hands back that text")
    func acceptedDuplicateReturnsMessage() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // The relay's event-id dedupe accepts and says so in the message, with no
        // payload. A caller cannot distinguish that from a real answer without the
        // text, which is the whole reason this variant exists.
        let event = try await signer.sign(kind: .directMessageOpen, content: "")
        let publishTask = Task { try await connection.publishAwaitingResponse(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, true, "duplicate: already processed"))

        #expect(try await publishTask.value == "duplicate: already processed")
        await connection.stop()
    }

    @Test("a duplicate rejection resolves as success carrying its raw message")
    func rejectedDuplicateResolvesWithMessage() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // `OK(false, "duplicate: …")` is success by classification — the existing
        // contract. The raw message travels with it, prefix intact, so a command
        // caller sees the same fact whichever way the relay spells it.
        let event = try await signer.sign(kind: .channelMessage, content: "dup")
        let publishTask = Task { try await connection.publishAwaitingResponse(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, false, "duplicate: already stored"))

        #expect(try await publishTask.value == "duplicate: already stored")
        await connection.stop()
    }

    @Test("a terminal rejection throws the classified reason, as the void form does")
    func terminalRejectionThrows() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .directMessageOpen, content: "")
        let publishTask = Task { try await connection.publishAwaitingResponse(event) }
        _ = await relay.awaitSend(index: 1)
        await relay.enqueue(Frames.ok(event.id, false, "restricted: not a relay member"))

        await #expect(throws: RelayConnectionError.publishRejected(.restricted("not a relay member"))) {
            _ = try await publishTask.value
        }
        await connection.stop()
    }

    @Test("a second in-flight publish of one event id is refused here too")
    func duplicateInFlightIsRefused() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        let connection = makeInertConnection(signer: signer, transports: transports)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        // The response variant shares the pending-publish table, so it shares the
        // refusal. A command's retry path must therefore re-sign to a *fresh* id
        // rather than resend the same event.
        let event = try await signer.sign(kind: .directMessageOpen, content: "")
        let firstPublish = Task { try await connection.publishAwaitingResponse(event) }
        _ = await relay.awaitSend(index: 1)

        await #expect(throws: RelayConnectionError.duplicatePublish) {
            _ = try await connection.publishAwaitingResponse(event)
        }

        await relay.enqueue(Frames.okEncoding(event.id, true, Self.commandPayload))
        #expect(try await firstPublish.value == Self.commandPayload)
        await connection.stop()
    }

    @Test("a publish whose OK never arrives times out rather than hanging")
    func timesOutWithoutOK() async throws {
        let signer = try InMemorySigner()
        let relay = FakeRelay()
        let transports = TransportQueue([relay])
        var config = inertConfig()
        config.publishTimeout = .milliseconds(80)
        let connection = makeInertConnection(signer: signer, transports: transports, config: config)

        try await connection.connect()
        try await driveAuthToReady(connection, relay, authSendIndex: 0)

        let event = try await signer.sign(kind: .directMessageOpen, content: "")
        await #expect(throws: RelayConnectionError.timedOut) {
            _ = try await connection.publishAwaitingResponse(event)
        }
        await connection.stop()
    }
}
