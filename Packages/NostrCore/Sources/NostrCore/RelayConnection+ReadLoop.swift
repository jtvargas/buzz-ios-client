import Foundation

/// The socket read loop, dead-connection watchdog, and the connection-loss path
/// they both feed into.
extension RelayConnection {
    // MARK: - Read loop

    func readLoop(generation: Int, transport: any RelayTransport) async {
        while true {
            let frame: String
            do {
                frame = try await transport.receive()
            } catch {
                await handleConnectionLost(generation: generation)
                return
            }
            guard generation == currentGeneration else { return }
            await handle(frameText: frame, generation: generation)
        }
    }

    /// Routes one raw frame. Internal for direct, timing-free tests of the
    /// generation guard and frame routing.
    func handle(frameText: String, generation: Int) async {
        guard generation == currentGeneration else { return }

        let message: RelayMessage
        do {
            message = try RelayMessage.decode(from: Data(frameText.utf8))
        } catch {
            // Untrusted input: a malformed or future-typed frame is logged-and-
            // skipped at the caller's discretion, never fatal.
            return
        }

        switch message {
        case let .authChallenge(challenge):
            await respondToChallenge(challenge, generation: generation)
        case let .ok(eventID, accepted, reason):
            await handleOK(eventID: eventID, accepted: accepted, message: reason, generation: generation)
        case let .event(subscriptionID, event):
            routeEvent(event, for: subscriptionID)
        case let .eose(subscriptionID):
            await routeEndOfStoredEvents(subscriptionID)
        case let .closed(subscriptionID, reason):
            await handleClosed(subscriptionID, message: reason, generation: generation)
        case .notice:
            break // advisory; using unspecified notice text for control flow would be guessing
        }
    }

    // MARK: - Connection loss

    /// `immediateReconnect` skips the backoff schedule and reconnects at once. The
    /// foreground liveness probe passes it: a resume that proves a frozen socket
    /// dead wants recovery now — the user is watching the screen — not on a backoff
    /// the watchdog paths still honour.
    func handleConnectionLost(generation: Int, immediateReconnect: Bool = false) async {
        guard generation == currentGeneration else { return }
        if authTerminated || isStopping { return }
        if case .stopped = state { return }
        if case .suspended = state { return }

        advanceGeneration() // stale-guard the dead socket's late deliveries
        watchdogTask?.cancel(); watchdogTask = nil
        await closeTransport()
        failInFlight(with: .connectionLost)
        authenticatedAs = nil
        authFailure = nil // a fresh socket re-authenticates cleanly

        if reconnectSuppressed { return }

        // A connection that stayed healthy long enough earns a fresh backoff
        // schedule; a flapping one keeps climbing.
        if let established = connectionEstablishedAt {
            let uptime = now() - established
            if config.reconnectPolicy.isHealthy(afterUpFor: uptime) {
                reconnectAttempt = 0
            }
        }
        connectionEstablishedAt = nil

        reconnectTask = Task { [weak self] in
            if immediateReconnect {
                await self?.reconnectImmediately()
            } else {
                await self?.runReconnectLoop()
            }
        }
    }

    func failInFlight(with error: RelayConnectionError) {
        let publishes = pendingPublishes
        pendingPublishes.removeAll()
        for continuation in publishes.values {
            continuation.resume(throwing: error)
        }

        let queries = oneShotQueries
        oneShotQueries.removeAll()
        for query in queries.values {
            query.continuation.resume(throwing: error)
        }
    }

    // MARK: - Watchdog

    func runWatchdog(generation: Int, transport: any RelayTransport) async {
        while generation == currentGeneration {
            do {
                try await sleep(config.pingInterval)
            } catch {
                return
            }
            guard generation == currentGeneration else { return }
            await performLivenessCheck(generation: generation, transport: transport)
        }
    }

    /// One liveness iteration. Internal so a test can drive it with a scripted
    /// idle interval and a failing ping, proving the dead-connection path without
    /// spending real time.
    func performLivenessCheck(generation: Int, transport: any RelayTransport) async {
        guard generation == currentGeneration else { return }
        guard let idle = await transport.idleInterval() else { return }
        guard generation == currentGeneration else { return }

        // Silent past the hard bound: declare it dead without waiting on a ping.
        if idle >= config.idleTimeout {
            await handleConnectionLost(generation: generation)
            return
        }

        // Idle past the soft bound: prove the peer is still there with a bounded
        // ping. A ping that errors or does not answer in time is a dead socket.
        if idle >= config.pingInterval {
            let alive = await pingSucceeds(within: config.pingDeadline, transport: transport)
            guard generation == currentGeneration else { return }
            if !alive {
                await handleConnectionLost(generation: generation)
            }
        }
    }

    private func pingSucceeds(within deadline: Duration, transport: any RelayTransport) async -> Bool {
        let sleepFn = sleep
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask { await (try? transport.ping()) != nil }
            group.addTask {
                _ = try? await sleepFn(deadline)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    // MARK: - Foreground liveness probe

    /// Arms a bounded liveness probe for a foregrounded `.ready` socket.
    ///
    /// # Why foreground must probe, not trust `.ready`
    ///
    /// iOS freezes the process the instant it is backgrounded, so the grace timer
    /// (``background()``) never runs while frozen and a quick return finds the
    /// state still `.ready` from before. But a frozen process cannot service its
    /// socket, and the OS — or an idle proxy in front of the relay (this relay is
    /// reached through a `tailscale serve` TLS terminator that reaps idle TCP) — can
    /// drop the connection silently. `URLSession` keeps reporting the task connected
    /// until the next read or write fails, so the parked read loop learns nothing
    /// and the idle watchdog would not notice for a full ``RelayConnectionConfig/idleTimeout``.
    /// The resume therefore proves liveness with a bounded ping instead of assuming
    /// it; a failed probe is a dead socket, torn down and reconnected at once so the
    /// fresh `.ready` drives the sync engine's catch-up reconcile.
    func armForegroundProbe() {
        foregroundProbeTask?.cancel()
        foregroundProbeTask = Task { [weak self, generation = currentGeneration] in
            await self?.probeForegroundLiveness(generation: generation)
        }
    }

    /// One foreground liveness iteration. Internal so a test drives it directly
    /// against a scripted live or dead socket, proving the probe without real time.
    func probeForegroundLiveness(generation: Int) async {
        guard generation == currentGeneration else { return }
        guard case .ready = state, let transport else { return }

        if await pingSucceeds(within: config.foregroundProbeDeadline, transport: transport) {
            return // the socket answered — keep it, no churn
        }
        // The probe may have raced a real drop the read loop already handled.
        guard generation == currentGeneration else { return }
        await handleConnectionLost(generation: generation, immediateReconnect: true)
    }

    // MARK: - Send

    func send(_ message: ClientMessage) async throws {
        guard let transport else { throw RelayConnectionError.notConnected }
        try await transport.send(message.encoded())
    }
}
