import Foundation

/// Publishing, one-shot queries, and the routing of subscription frames the
/// connection does not consume itself.
extension RelayConnection {
    // MARK: - Publishing

    /// Publishes an event and suspends until the relay's `OK`. A rejection is
    /// classified through ``OKReason``: a `duplicate:` counts as success (the
    /// relay already has it); anything else fails with the typed reason so the
    /// caller's retry policy can act. A disconnect fails the publish with
    /// ``RelayConnectionError/connectionLost`` — the outbox owns the resend.
    public func publish(_ event: NostrEvent, timeout: Duration? = nil) async throws {
        _ = try await publishAwaitingResponse(event, timeout: timeout)
    }

    /// Publishes an event and returns the *message text* of the relay's `OK`.
    ///
    /// Identical to ``publish(_:timeout:)`` in every respect — the same
    /// relay-signed-kind guard, the same refusal of a second in-flight publish of
    /// one event id, the same `duplicate:`-is-success classification, the same
    /// watchdog, the same `connectionLost` on a drop — and in fact its
    /// implementation; only the return value differs.
    ///
    /// # Why the message matters
    ///
    /// NIP-01 treats the fourth `OK` field as human-readable, so the durable send
    /// path discards it. Buzz's *command* kinds do not: the relay answers them with
    /// a machine-readable payload in exactly that field
    /// (`"response:{…json…}"`), and it is the only place the result appears — a
    /// command's outcome is never fanned out as an event. A caller of a command kind
    /// therefore needs the text, and getting it must not cost the outbox its
    /// `Void`-returning contract.
    ///
    /// The returned string is the raw message, including any `duplicate: …` prefix
    /// on the success-by-classification path: distinguishing "the relay processed my
    /// command" from "the relay recognised this event id and did nothing" is the
    /// caller's job, and it needs the text to do it.
    public func publishAwaitingResponse(_ event: NostrEvent, timeout: Duration? = nil) async throws -> String {
        guard !event.kind.isRelaySigned else {
            throw RelayConnectionError.publishRejected(.restricted("kind \(event.kind) is signed by the relay"))
        }
        // Storing a second continuation under the same id would silently strand
        // the first caller with no path to resumption — refuse instead.
        guard pendingPublishes[event.id] == nil else {
            throw RelayConnectionError.duplicatePublish
        }
        try await waitForAuthentication()

        let deadline = timeout ?? config.publishTimeout
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await sleep(deadline)
            await timeOutPublish(event.id)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            pendingPublishes[event.id] = continuation
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await send(.event(event))
                } catch {
                    // A send failure must resume the caller immediately —
                    // never leave it waiting on a watchdog timeout.
                    await failPublish(event.id, with: .connectionLost)
                }
            }
        }
    }

    private func timeOutPublish(_ eventID: String) {
        // A relay that never answers — or answers with a frame that fails
        // decode — must not hang the caller while subscription traffic keeps
        // the idle watchdog satisfied.
        pendingPublishes.removeValue(forKey: eventID)?
            .resume(throwing: RelayConnectionError.timedOut)
    }

    func resolvePublish(_ eventID: String, accepted: Bool, message: String) {
        guard let continuation = pendingPublishes.removeValue(forKey: eventID) else { return }
        if accepted {
            continuation.resume(returning: message)
            return
        }
        let reason = OKReason(message: message)
        if reason.disposition == .alreadyAccepted {
            // Success by classification. The raw message travels with it so a
            // command caller can tell an actioned publish from a deduped one.
            continuation.resume(returning: message)
        } else {
            continuation.resume(throwing: RelayConnectionError.publishRejected(reason))
        }
    }

    private func failPublish(_ eventID: String, with error: RelayConnectionError) {
        pendingPublishes.removeValue(forKey: eventID)?.resume(throwing: error)
    }

    // MARK: - One-shot query

    /// Runs a one-shot query: REQ, collect until EOSE, resolve, CLOSE. Used for
    /// NIP-50 search and state fetches; never replayed after a reconnect, so a
    /// disconnect mid-flight throws ``RelayConnectionError/connectionLost`` and
    /// the caller decides whether the answer is still wanted. A partial delivery
    /// interrupted before EOSE is never returned as if complete — the throw is
    /// the only outcome.
    ///
    /// A `CLOSED auth-required` is retried exactly once after re-authenticating;
    /// a `restricted:` (or any other terminal) close is surfaced without retry.
    public func query(_ filters: [Filter], timeout: Duration? = nil) async throws -> [NostrEvent] {
        try await waitForAuthentication()

        let subscriptionID = makeSubscriptionID()
        let deadline = timeout ?? config.queryTimeout
        let timeoutTask = Task { [weak self] in
            guard let self else { return }
            try? await sleep(deadline)
            await timeOutQuery(subscriptionID)
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[NostrEvent], Error>) in
            oneShotQueries[subscriptionID] = PendingQuery(filters: filters, continuation: continuation)
            Task { [weak self] in
                guard let self else { return }
                do {
                    try await send(.req(subscriptionID: subscriptionID, filters: filters))
                } catch {
                    // The reference defect fixed: a send failure resumes the
                    // caller immediately rather than leaking the continuation
                    // until a watchdog.
                    await failQuery(subscriptionID, with: .connectionLost)
                }
            }
        }
    }

    private func timeOutQuery(_ subscriptionID: String) async {
        guard let query = oneShotQueries.removeValue(forKey: subscriptionID) else { return }
        query.continuation.resume(throwing: RelayConnectionError.timedOut)
        try? await send(.close(subscriptionID: subscriptionID))
    }

    private func failQuery(_ subscriptionID: String, with error: RelayConnectionError) {
        oneShotQueries.removeValue(forKey: subscriptionID)?.continuation.resume(throwing: error)
    }

    private func isQueryPending(_ subscriptionID: String) -> Bool {
        oneShotQueries[subscriptionID] != nil
    }

    private func makeSubscriptionID() -> String {
        nextSubscriptionID += 1
        return "q\(nextSubscriptionID)"
    }

    // MARK: - Subscription frame routing

    func routeEvent(_ event: NostrEvent, for subscriptionID: String) {
        if var query = oneShotQueries[subscriptionID] {
            query.collected.append(event)
            oneShotQueries[subscriptionID] = query
            return
        }
        yieldInbound(.event(subscriptionID: subscriptionID, event: event))
    }

    func routeEndOfStoredEvents(_ subscriptionID: String) async {
        if let query = oneShotQueries.removeValue(forKey: subscriptionID) {
            query.continuation.resume(returning: query.collected)
            try? await send(.close(subscriptionID: subscriptionID))
            return
        }
        yieldInbound(.endOfStoredEvents(subscriptionID: subscriptionID))
    }

    func handleClosed(_ subscriptionID: String, message: String, generation: Int) async {
        guard generation == currentGeneration else { return }
        let reason = OKReason(message: message)

        if var query = oneShotQueries[subscriptionID] {
            // A relay that forgot our auth (e.g. after a restart) closes with
            // `auth-required`. Re-authenticate and retry the query once; a
            // genuinely forbidden query (`restricted:`) is never retried and
            // hammered.
            if reason.disposition == .reauthThenRetry, !query.retriedAfterAuth {
                query.retriedAfterAuth = true
                oneShotQueries[subscriptionID] = query
                authenticatedAs = nil
                state = .authenticating
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await waitForAuthentication()
                        // The socket may have dropped while re-auth was in
                        // flight, failing this query via failInFlight. Re-sending
                        // then would open a zombie relay-side subscription no
                        // one ever CLOSEs.
                        guard await isQueryPending(subscriptionID) else { return }
                        try await send(.req(subscriptionID: subscriptionID, filters: query.filters))
                    } catch {
                        await failQuery(subscriptionID, with: .subscriptionClosed(reason))
                    }
                }
                return
            }
            oneShotQueries.removeValue(forKey: subscriptionID)
            query.continuation.resume(throwing: RelayConnectionError.subscriptionClosed(reason))
            return
        }

        yieldInbound(.closed(subscriptionID: subscriptionID, reason: reason))
    }
}
