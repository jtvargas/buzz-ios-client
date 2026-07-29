import Foundation

/// The NIP-42 handshake: answering a challenge, tracking the pending answer,
/// completing auth inline, gating sends on it, and the terminal-rejection stop.
extension RelayConnection {
    // MARK: - Challenge / response

    func respondToChallenge(_ challenge: String, generation: Int) async {
        guard generation == currentGeneration else { return }
        state = .authenticating
        authFailure = nil // a fresh challenge supersedes any prior failure

        let event: NostrEvent
        do {
            event = try await signer.sign(
                kind: .clientAuthentication,
                content: "",
                tags: Self.authTags(challenge: challenge, relayURL: url)
            )
        } catch {
            guard generation == currentGeneration else { return }
            completeAuth(with: .failure(.authenticationFailed(String(describing: error))))
            return
        }

        guard generation == currentGeneration else { return }
        pendingAuthEventID = event.id
        do {
            try await send(.auth(event))
        } catch {
            guard generation == currentGeneration else { return }
            completeAuth(with: .failure(.authenticationFailed(String(describing: error))))
        }
    }

    /// The NIP-42 kind-22242 answer tags. `relay` names this relay so a signed
    /// answer cannot be replayed against another; `challenge` echoes the exact
    /// token the relay issued.
    static func authTags(challenge: String, relayURL: URL) -> [[String]] {
        [
            ["relay", relayURL.absoluteString],
            ["challenge", challenge],
        ]
    }

    private func completeAuth(with result: Result<PublicKey, RelayConnectionError>) {
        pendingAuthEventID = nil
        switch result {
        case let .success(key):
            authenticatedAs = key
            authFailure = nil
            // The handshake landed inside its deadline; disarm it. The deadline also
            // checks the state before acting, so this is belt to that braces — but a
            // timer left running against a healthy socket is the kind that later fires.
            handshakeTask?.cancel(); handshakeTask = nil
            state = .ready
            resumeAuthWaiters(.success(()))
        case let .failure(error):
            authenticatedAs = nil
            authFailure = error
            resumeAuthWaiters(.failure(error))
        }
    }

    // MARK: - Waiting for auth

    /// Suspends until the relay has accepted our identity. Every publish and
    /// query passes through here.
    func waitForAuthentication() async throws {
        if state == .ready, authenticatedAs != nil { return }
        if authTerminated { throw authFailure ?? .authenticationRejected("") }
        if isStopping { throw RelayConnectionError.stopped }
        if case .stopped = state { throw RelayConnectionError.notConnected }
        if case .suspended = state { throw RelayConnectionError.notConnected }
        if let authFailure { throw authFailure }

        let id = nextWaiterID
        nextWaiterID += 1

        // A per-waiter watchdog: a recorded failure covers the orderings we
        // anticipated, but an unresumed continuation is uncancellable, so a
        // last-resort timeout is the only thing that can rescue a race we did
        // not.
        let watchdog = Task { [weak self] in
            guard let self else { return }
            try? await sleep(config.authTimeout)
            await timeOutAuthWaiter(id)
        }
        defer { watchdog.cancel() }

        try await withCheckedThrowingContinuation { continuation in
            authWaiters[id] = continuation
        }
    }

    private func timeOutAuthWaiter(_ id: Int) {
        authWaiters.removeValue(forKey: id)?.resume(throwing: RelayConnectionError.timedOut)
    }

    /// The memoized auth failure, exposed internally so a test can wait until a
    /// rejection is recorded before proving a later waiter fails fast.
    var currentAuthFailure: RelayConnectionError? {
        authFailure
    }

    func resumeAuthWaiters(_ result: Result<Void, Error>) {
        let waiters = authWaiters
        authWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume(with: result)
        }
    }

    private func terminateForAuthRejection(reason: String) async {
        authTerminated = true
        reconnectSuppressed = true
        pendingAuthEventID = nil
        advanceGeneration()
        reconnectTask?.cancel(); reconnectTask = nil
        readTask?.cancel(); readTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        handshakeTask?.cancel(); handshakeTask = nil

        let error = RelayConnectionError.authenticationRejected(reason)
        authFailure = error
        failInFlight(with: error)
        resumeAuthWaiters(.failure(error))
        state = .stopped(.authRejected(reason: reason))
        await closeTransport()
    }

    // MARK: - OK routing

    func handleOK(eventID: String, accepted: Bool, message: String, generation: Int) async {
        guard generation == currentGeneration else { return }

        // The auth answer earns an OK like any event, so it must be told apart
        // before the publish table is consulted.
        if let pending = pendingAuthEventID, eventID == pending {
            if accepted {
                do {
                    let key = try await signer.publicKey()
                    guard generation == currentGeneration else { return }
                    completeAuth(with: .success(key))
                } catch {
                    completeAuth(with: .failure(.authenticationFailed(message)))
                }
            } else {
                let reason = OKReason(message: message)
                if reason.disposition == .terminal {
                    // The relay rejected this identity outright. Retrying would
                    // hammer it forever, so stop and surface it.
                    await terminateForAuthRejection(reason: message)
                } else {
                    completeAuth(with: .failure(.authenticationFailed(message)))
                }
            }
            return
        }

        resolvePublish(eventID, accepted: accepted, message: message)
    }
}
