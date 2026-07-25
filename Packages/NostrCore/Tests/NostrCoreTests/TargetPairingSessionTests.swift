import Foundation
@testable import NostrCore
import Testing

/// The target pairing state machine driven over a scripted channel with a real
/// source simulator — no socket, no timing flakiness. Covers both confirmation
/// orders, transcript mismatch, impostor rejection, duplicate/out-of-order events,
/// expiry, both abort directions, and complete-only-after-import.
@Suite struct TargetPairingSessionTests {
    static let sourcePriv = "7f4c11a9c9d1e3b5a7f2e4d6c8b0a2f4e6d8c0b2a4f6e8d0c2b4a6f8e0d2c4b5"
    static let sourcePub = "199e64ca60662cb2d6e91d16cb065be51ad74a6ee5f8c5b0fdc53d246611ed9a"
    static let targetPriv = "3a5b7c9d1e3f5a7b9c1d3e5f7a9b1c3d5e7f9a1b3c5d7e9f1a3b5c7d9e1f3a5b"
    static let targetPub = "89a9fa762105d0aee2b19678246fe7b823aabbc4f4bf691a1ce8a70fcd36d6e4"
    static let secret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
    static let sessionIDHex = "fb357d0f8e8d5a5ba3b2a91cb18c119e1567b07ffa38cdebb73e68df78f5a380"
    static let transcript = "d662818ff8911fc60a2d025f8b8b4756107104e85888dd202d28db5ca2cf28d3"
    static let sasCode = "863346"
    static let impostorPriv = "1111111111111111111111111111111111111111111111111111111111111111"

    // MARK: - Fixture

    private func makeSession(
        handler: RecordingPayloadHandler,
        channel: ScriptedPairingChannel,
        stepTimeout: Duration = .seconds(3600)
    ) throws -> TargetPairingSession {
        let raw = "nostrpair://\(Self.sourcePub)?secret=\(Self.secret)&relay=wss://pair.example"
        let uri = try NostrPairURI(parsing: raw)
        return try TargetPairingSession(
            uri: uri,
            handler: handler,
            targetKey: PrivateKey(hex: Self.targetPriv),
            makeConnection: { _, _, _ in channel },
            stepTimeout: stepTimeout,
            sessionTimeout: .seconds(3600),
            sleep: { try await Task.sleep(for: $0) }
        )
    }

    private func source() throws -> PairingSourceSimulator {
        try PairingSourceSimulator(sourcePrivateHex: Self.sourcePriv, targetPublicHex: Self.targetPub)
    }

    /// Deterministically awaits a phase matching `predicate`, or `nil` on timeout.
    private func awaitPhase(
        _ session: TargetPairingSession,
        timeout: Duration = .seconds(2),
        where predicate: @escaping @Sendable (TargetPairingPhase) -> Bool
    ) async -> TargetPairingPhase? {
        await withTaskGroup(of: TargetPairingPhase?.self) { group in
            group.addTask {
                for await phase in await session.phases() where predicate(phase) { return phase }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func parkBriefly() async { try? await Task.sleep(for: .milliseconds(40)) }

    private func aborts(_ published: [NostrEvent], _ source: PairingSourceSimulator) -> [PairingMessage] {
        published.compactMap { try? source.decode($0) }.filter { if case .abort = $0 { true } else { false } }
    }

    private func completes(_ published: [NostrEvent], _ source: PairingSourceSimulator) -> [PairingMessage] {
        published.compactMap { try? source.decode($0) }.filter { if case .complete = $0 { true } else { false } }
    }

    // MARK: - Happy path

    @Test func offerCarriesTheDerivedSessionIDAndShowsSAS() async throws {
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: RecordingPayloadHandler(), channel: channel)
        let source = try source()

        await session.start()

        #expect(await session.phase == .comparing(sasCode: Self.sasCode))
        let published = await channel.published
        #expect(try published.first.map { try source.decode($0) } == .offer(version: 1, sessionID: Self.sessionIDHex))
    }

    @Test func happyPathPayloadThenConfirm() async throws {
        let handler = RecordingPayloadHandler(importSucceeds: true)
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        try await channel.deliver(source.event(.sasConfirm(transcriptHash: Self.transcript)))
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))
        await parkBriefly()
        // Dual consent not met until the user confirms — nothing imported yet.
        #expect(await handler.received.isEmpty)

        await session.confirmSAS()
        #expect(await awaitPhase(session) { $0 == .completed } == .completed)

        #expect(await handler.received == [.init(payloadType: "custom", payload: "CRED")])
        #expect(await completes(channel.published, source) == [.complete(success: true)])
        #expect(await channel.closeCount >= 1)
    }

    @Test func happyPathConfirmThenPayload() async throws {
        let handler = RecordingPayloadHandler(importSucceeds: true)
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        await session.confirmSAS() // user confirms first
        try await channel.deliver(source.event(.sasConfirm(transcriptHash: Self.transcript)))
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))

        #expect(await awaitPhase(session) { $0 == .completed } == .completed)
        #expect(await handler.received == [.init(payloadType: "custom", payload: "CRED")])
    }

    // MARK: - Security paths

    @Test func transcriptMismatchAbortsAndNeverImports() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        let wrong = String(repeating: "00", count: 32)
        try await channel.deliver(source.event(.sasConfirm(transcriptHash: wrong)))

        #expect(await awaitPhase(session) { $0 == .failed(.transcriptMismatch) } == .failed(.transcriptMismatch))
        #expect(await aborts(channel.published, source) == [.abort(reason: "sas_mismatch")])

        // A payload arriving after the mismatch, even with a user confirm, is ignored.
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "X")))
        await session.confirmSAS()
        await parkBriefly()
        #expect(await handler.received.isEmpty)
    }

    @Test func userDenialSendsUserDeniedAbort() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        await session.cancel()

        #expect(await awaitPhase(session) { $0 == .cancelled } == .cancelled)
        #expect(await aborts(channel.published, source) == [.abort(reason: "user_denied")])
        #expect(await handler.received.isEmpty)
    }

    @Test func impostorEventFromWrongKeyIsDiscarded() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        let impostor = try source.impostorEvent(
            .sasConfirm(transcriptHash: Self.transcript), impostorPrivateHex: Self.impostorPriv
        )
        try await channel.deliver(impostor)
        await parkBriefly()
        // The impostor is ignored; the session is still waiting on the real source.
        #expect(await session.phase == .comparing(sasCode: Self.sasCode))

        // The genuine source still completes the session.
        try await channel.deliver(source.event(.sasConfirm(transcriptHash: Self.transcript)))
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))
        await session.confirmSAS()
        #expect(await awaitPhase(session) { $0 == .completed } == .completed)
    }

    @Test func duplicateSasConfirmIsProcessedOnce() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        let confirm = try source.event(.sasConfirm(transcriptHash: Self.transcript))
        try await channel.deliver(confirm)
        try await channel.deliver(confirm) // exact duplicate id
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))
        await session.confirmSAS()

        #expect(await awaitPhase(session) { $0 == .completed } == .completed)
        #expect(await handler.received.count == 1)
    }

    @Test func payloadBeforeSasConfirmIsDiscarded() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        // A payload arriving before sas-confirm is out-of-order — never acted on.
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))
        await session.confirmSAS()
        await parkBriefly()

        #expect(await session.phase == .comparing(sasCode: Self.sasCode))
        #expect(await handler.received.isEmpty)
    }

    @Test func stepTimeoutAborts() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel, stepTimeout: .milliseconds(50))
        let source = try source()

        await session.start()
        #expect(await awaitPhase(session) { $0 == .failed(.timedOut) } == .failed(.timedOut))
        #expect(await aborts(channel.published, source) == [.abort(reason: "timeout")])
    }

    @Test func peerAbortTerminatesWithoutRepublishing() async throws {
        let handler = RecordingPayloadHandler()
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        try await channel.deliver(source.event(.abort(reason: "user_denied")))

        let final = await awaitPhase(session) { if case .failed(.peerAborted) = $0 { true } else { false } }
        #expect(final == .failed(.peerAborted("user_denied")))
        // We do not answer a peer abort with an abort of our own.
        #expect(await aborts(channel.published, source).isEmpty)
    }

    @Test func importFailureSendsCompleteFalse() async throws {
        let handler = RecordingPayloadHandler(importSucceeds: false)
        let channel = ScriptedPairingChannel()
        let session = try makeSession(handler: handler, channel: channel)
        let source = try source()

        await session.start()
        try await channel.deliver(source.event(.sasConfirm(transcriptHash: Self.transcript)))
        try await channel.deliver(source.event(.payload(payloadType: "custom", payload: "CRED")))
        await session.confirmSAS()

        let final = await awaitPhase(session) { if case .failed(.importFailed) = $0 { true } else { false } }
        #expect(final == .failed(.importFailed("could not import the received identity")))
        #expect(await handler.received.count == 1)
        // complete(false) went out — never complete(true) on a failed import.
        #expect(await completes(channel.published, source) == [.complete(success: false)])
    }

    @Test func openFailureSurfacesAsFailure() async throws {
        let channel = ScriptedPairingChannel()
        await channel.failOpen(NostrPairError.connectionFailed("no route"))
        let session = try makeSession(handler: RecordingPayloadHandler(), channel: channel)

        await session.start()
        let final = await awaitPhase(session) { if case .failed(.connectionFailed) = $0 { true } else { false } }
        #expect(final == .failed(.connectionFailed("no route")))
    }
}
