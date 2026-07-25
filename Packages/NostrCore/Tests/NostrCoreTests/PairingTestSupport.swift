import Foundation
@testable import NostrCore

/// A scripted ``PairingChannel`` — the seam that lets the whole target state machine
/// run with no socket. Tests script the open outcome and per-publish `OK` verdicts,
/// read back everything the session published, and feed inbound events on demand.
actor ScriptedPairingChannel: PairingChannel {
    private(set) var published: [NostrEvent] = []
    private var inboundContinuation: AsyncStream<NostrEvent>.Continuation?
    private var buffered: [NostrEvent] = []
    private var openError: Error?
    private var publishVerdicts: [Bool] = []
    private var isClosed = false
    private(set) var closeCount = 0

    func failOpen(_ error: Error) { openError = error }

    /// Scripts the `OK` verdicts publishes return, in order; publishes past the
    /// script default to `true` (the main-relay behaviour).
    func scriptPublishVerdicts(_ verdicts: [Bool]) { publishVerdicts = verdicts }

    func open() async throws {
        if let openError { throw openError }
    }

    func publish(_ event: NostrEvent) async throws -> Bool {
        published.append(event)
        guard !publishVerdicts.isEmpty else { return true }
        return publishVerdicts.removeFirst()
    }

    func inboundEvents() async -> AsyncStream<NostrEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NostrEvent.self)
        inboundContinuation = continuation
        for event in buffered { continuation.yield(event) }
        buffered.removeAll()
        if isClosed { continuation.finish() }
        return stream
    }

    /// Feeds one inbound event. Buffered until the session opens its stream, so a
    /// test need not race the session's setup.
    func deliver(_ event: NostrEvent) {
        if let inboundContinuation {
            inboundContinuation.yield(event)
        } else {
            buffered.append(event)
        }
    }

    func close() async {
        closeCount += 1
        isClosed = true
        inboundContinuation?.finish()
        inboundContinuation = nil
    }
}

/// Plays the _source_ (desktop) side: builds real, signed, NIP-44-encrypted
/// `kind:24134` events so the target session's decrypt/verify path is exercised
/// end-to-end, and decodes what the target published back.
struct PairingSourceSimulator {
    let sourceKey: PrivateKey
    let targetPublicKey: PublicKey
    let conversationKey: Data

    init(sourcePrivateHex: String, targetPublicHex: String) throws {
        sourceKey = try PrivateKey(hex: sourcePrivateHex)
        targetPublicKey = PublicKey(hex: targetPublicHex)!
        conversationKey = try NIP44.conversationKey(privateKey: sourceKey, peer: targetPublicKey)
    }

    /// A signed, encrypted event from the source addressed to the target.
    func event(_ message: PairingMessage) throws -> NostrEvent {
        let ciphertext = try NIP44.encrypt(message.jsonString(), conversationKey: conversationKey)
        return try NostrEvent.signed(
            kind: .devicePairing,
            content: ciphertext,
            tags: [["p", targetPublicKey.hex]],
            with: sourceKey
        )
    }

    /// An event from an *impostor* key (a race/stolen-QR attacker) — a different
    /// author than the QR's source, which the target must reject.
    func impostorEvent(_ message: PairingMessage, impostorPrivateHex: String) throws -> NostrEvent {
        let impostor = try PrivateKey(hex: impostorPrivateHex)
        let key = try NIP44.conversationKey(privateKey: impostor, peer: targetPublicKey)
        let ciphertext = try NIP44.encrypt(message.jsonString(), conversationKey: key)
        return try NostrEvent.signed(
            kind: .devicePairing, content: ciphertext, tags: [["p", targetPublicKey.hex]], with: impostor
        )
    }

    /// Decodes what the target published (offer/abort/complete) back to a message.
    func decode(_ event: NostrEvent) throws -> PairingMessage {
        let plaintext = try NIP44.decrypt(event.content, conversationKey: conversationKey)
        return try PairingMessage.decode(json: plaintext)
    }
}

/// Records the credential the session hands over, and scripts the durable-import
/// verdict. Returning `false` models a Keychain write failure.
actor RecordingPayloadHandler: PairingPayloadHandler {
    struct Received: Sendable, Equatable {
        let payloadType: String
        let payload: String
    }

    private(set) var received: [Received] = []
    private let result: Bool

    init(importSucceeds: Bool = true) { result = importSucceeds }

    func importPayload(payloadType: String, payload: String) async -> Bool {
        received.append(Received(payloadType: payloadType, payload: payload))
        return result
    }
}
