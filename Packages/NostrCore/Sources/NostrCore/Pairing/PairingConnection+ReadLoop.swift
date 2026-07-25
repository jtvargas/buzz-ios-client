import Foundation

/// The pairing connection's frame pump: pulling frames, answering an optional
/// NIP-42 challenge, routing `OK`/`EOSE`, and forwarding inbound pairing events.
extension PairingConnection {
    /// Pulls frames until the socket drops or the connection is torn down. A
    /// receive error is a dead socket, which ends the session.
    func readLoop(_ transport: any RelayTransport) async {
        while !Task.isCancelled {
            let text: String
            do {
                text = try await transport.receive()
            } catch {
                await failClosed(NostrPairError.connectionFailed(String(describing: error)))
                return
            }
            await handle(text)
        }
    }

    private func handle(_ text: String) async {
        // Relay input is untrusted: a frame that does not decode is logged-and-skipped,
        // never fatal.
        guard let message = try? RelayMessage.decode(from: Data(text.utf8)) else { return }

        switch message {
        case let .authChallenge(challenge):
            await respondToChallenge(challenge)
        case let .ok(eventID, accepted, message):
            handleOK(eventID: eventID, accepted: accepted, message: message)
        case let .eose(subscriptionID):
            if subscriptionID == self.subscriptionID { resolveEOSE(.success(())) }
        case let .event(subscriptionID, event):
            if subscriptionID == self.subscriptionID { yieldInbound(event) }
        case let .closed(subscriptionID, message):
            if subscriptionID == self.subscriptionID {
                await failClosed(NostrPairError.connectionFailed("subscription closed: \(message)"))
            }
        case .notice:
            break // a human-readable notice is not a protocol verdict
        }
    }

    /// Answers a NIP-42 challenge under the ephemeral key. The answer's `OK`
    /// resolves the auth phase; a signing or send failure fails it.
    private func respondToChallenge(_ challenge: String) async {
        challengeSeen = true
        guard let transport else { return }

        let event: NostrEvent
        do {
            event = try await signer.sign(
                kind: .clientAuthentication,
                content: "",
                tags: RelayConnection.authTags(challenge: challenge, relayURL: url)
            )
        } catch {
            resolveAuth(.failure(NostrPairError.authenticationRejected(String(describing: error))))
            return
        }

        let frame: Data
        do {
            frame = try ClientMessage.auth(event).encoded()
        } catch {
            resolveAuth(.failure(NostrPairError.internalError(String(describing: error))))
            return
        }

        pendingAuthEventID = event.id
        do {
            try await transport.send(frame)
        } catch {
            resolveAuth(.failure(NostrPairError.connectionFailed(String(describing: error))))
        }
    }

    /// Routes an `OK`: the NIP-42 answer's verdict is told apart from a publish's by
    /// matching the pending auth event id exactly (id **and** `accepted`, never a
    /// substring of the message). Anything else resolves a pending publish.
    private func handleOK(eventID: String, accepted: Bool, message: String) {
        if let pending = pendingAuthEventID, eventID == pending {
            pendingAuthEventID = nil
            if accepted {
                resolveAuth(.success(()))
            } else {
                resolveAuth(.failure(NostrPairError.authenticationRejected(message)))
            }
            return
        }
        resolvePublish(eventID, accepted: accepted)
    }
}
