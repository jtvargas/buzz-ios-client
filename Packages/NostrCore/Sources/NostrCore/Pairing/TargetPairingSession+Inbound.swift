import Foundation

/// The target session's protocol flow: publishing the offer, validating and routing
/// inbound events, verifying the transcript, enforcing dual consent, and completing
/// the transfer.
extension TargetPairingSession {
    // MARK: - Offer

    /// Publishes the offer after the channel is open (EOSE-gated). Retries the
    /// *same* signed offer on an `OK false` — a dedicated pairing sidecar rejects an
    /// offer when no live source is subscribed yet and permits a retry; the main
    /// relay accepts unconditionally, so the retry path never fires there. If every
    /// attempt is rejected, the source is not reachable and the session fails.
    ///
    /// # The code is shown only once the offer is on its way
    ///
    /// ``TargetPairingPhase/comparing(sasCode:)`` asks the reader to check a number
    /// against their desktop, so it must not appear until the desktop has actually
    /// been asked. This used to be set *before* the publish, which made two very
    /// different situations look identical on the phone: an offer sitting on the
    /// desktop waiting to be confirmed, and an offer that never left. Both showed a
    /// code and then, thirty seconds later, a timeout — with nothing to say which had
    /// happened. The relay's `OK` is the first moment the phone knows the offer is
    /// somewhere the desktop can reach, so that is where the code appears.
    ///
    /// The *state* still moves before the publish: a source can answer the instant
    /// the relay fans the offer out, and an inbound `sas-confirm` arriving while this
    /// session still called itself `.connecting` would be discarded as out-of-order.
    func publishOffer() async {
        guard internalState == .connecting else { return }
        let offer = PairingMessage.offer(version: NostrPairURI.supportedVersion, sessionID: sessionID.hexString)
        guard let event = try? await encryptAndSign(offer) else {
            await fail(.internalError("could not build the offer"))
            return
        }

        internalState = .awaitingSasConfirm
        armStepDeadline()

        var attemptsLeft = 3
        while attemptsLeft > 0, !internalState.isTerminal {
            let accepted: Bool
            do {
                accepted = try await connection?.publish(event) ?? false
            } catch {
                // The socket dropped mid-publish. Reported rather than left to the
                // deadline: waiting thirty seconds to say "timed out" describes the
                // clock, not what went wrong.
                guard !internalState.isTerminal else { return }
                await fail(mapConnectionError(error))
                return
            }
            if accepted {
                // Delivered. Only now is there a code worth comparing.
                if !internalState.isTerminal { setPhase(.comparing(sasCode: sasCode)) }
                return
            }
            attemptsLeft -= 1
            if attemptsLeft > 0 { try? await sleep(.seconds(1)) }
        }
        if !internalState.isTerminal {
            await fail(.connectionFailed("the other device isn't ready — restart pairing on your desktop"))
        }
    }

    // MARK: - Inbound routing

    /// Validates, de-duplicates, and routes one inbound event by protocol state.
    /// Every rejection is a silent discard — the relay is never told why.
    func handleInbound(_ event: NostrEvent) async {
        guard !internalState.isTerminal else { return }
        guard !processedEventIDs.contains(event.id) else { return }
        guard isValidInboundEvent(event) else { return }
        processedEventIDs.insert(event.id)

        switch internalState {
        case .awaitingSasConfirm:
            await handleSasConfirmState(event)
        case .awaitingConfirmation:
            // Buffer the raw ciphertext undecrypted; do not act on the payload until
            // dual consent. An abort here is discovered only after consent — the
            // source does not abort once it has sent `sas-confirm`.
            bufferPayload(event)
            await advanceIfDualConsent()
        case .idle, .connecting, .transferring, .terminal:
            break // no inbound expected in these states
        }
    }

    /// NIP-AB §Event Validation: right kind, expected peer, `p`-tag addressed to us,
    /// content within the NIP-44 payload-length window, and a valid id+signature.
    private func isValidInboundEvent(_ event: NostrEvent) -> Bool {
        guard event.kind == .devicePairing else { return false }
        guard matchesSourcePeer(event) else { return false }
        guard isAddressedToUs(event) else { return false }
        let length = event.content.count
        guard length >= 132, length <= 87472 else { return false }
        return event.isValid
    }

    // MARK: - sas-confirm

    private func handleSasConfirmState(_ event: NostrEvent) async {
        guard let message = try? decryptMessage(event.content) else { return }
        switch message {
        case let .sasConfirm(transcriptHash):
            await verifyTranscript(transcriptHash)
        case let .abort(reason):
            await handlePeerAbort(reason)
        default:
            break // out-of-order (e.g. a payload before sas-confirm) — silent discard
        }
    }

    private func verifyTranscript(_ received: String) async {
        guard let receivedBytes = Data(hexString: received), receivedBytes.count == 32,
              PairingCrypto.constantTimeEquals(receivedBytes, expectedTranscript())
        else {
            await abortTranscriptMismatch()
            return
        }
        transcriptVerified = true
        internalState = .awaitingConfirmation
        armStepDeadline()
        await advanceIfDualConsent()
    }

    private func abortTranscriptMismatch() async {
        // Discard any payload received early; it may already be in transit.
        bufferedPayloadCiphertext = nil
        await sendAbort(.sasMismatch)
        await fail(.transcriptMismatch)
    }

    func handlePeerAbort(_ reason: String) async {
        // The peer already aborted; do not send one back (§Abort).
        await terminate(.failed(.peerAborted(reason)))
    }

    // MARK: - Payload buffering & dual consent

    private func bufferPayload(_ event: NostrEvent) {
        guard bufferedPayloadCiphertext == nil else { return } // first only
        bufferedPayloadCiphertext = event.content
    }

    func advanceIfDualConsent() async {
        guard internalState == .awaitingConfirmation,
              transcriptVerified, userConfirmed,
              let ciphertext = bufferedPayloadCiphertext
        else { return }

        internalState = .transferring
        cancelStepDeadline()
        setPhase(.transferring)
        await completeTransfer(ciphertext)
    }

    // MARK: - Transfer

    private func completeTransfer(_ ciphertext: String) async {
        guard let message = try? decryptMessage(ciphertext) else {
            await fail(.invalidPayload("the received payload could not be decrypted"))
            return
        }
        switch message {
        case let .payload(payloadType, payload):
            await importCredential(payloadType: payloadType, payload: payload)
        case let .abort(reason):
            await handlePeerAbort(reason)
        default:
            await fail(.invalidPayload("unexpected message after confirmation"))
        }
    }

    private func importCredential(payloadType: String, payload: String) async {
        let imported = await handler.importPayload(payloadType: payloadType, payload: payload)
        if imported {
            // `complete(true)` only AFTER a durable import (NIP-AB Step 5).
            await sendComplete(success: true)
            await terminate(.completed)
        } else {
            await sendComplete(success: false)
            await fail(.importFailed("could not import the received identity"))
        }
    }

    private func sendComplete(success: Bool) async {
        guard let event = try? await encryptAndSign(.complete(success: success)) else { return }
        await publishBestEffort(event)
    }

    // MARK: - Error mapping

    func mapConnectionError(_ error: Error) -> NostrPairError {
        (error as? NostrPairError) ?? .connectionFailed(String(describing: error))
    }
}
