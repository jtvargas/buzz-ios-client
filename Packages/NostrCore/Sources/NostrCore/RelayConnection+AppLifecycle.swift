import Foundation

/// What the app going away and coming back does to the socket: the background grace
/// window, the suspension it ends in, and the resume that undoes both.
extension RelayConnection {
    /// Arms the background grace window. If the app returns to the foreground within
    /// it, the socket is kept; otherwise the socket is released. A quick app switch
    /// therefore does not churn the connection.
    public func background() {
        guard !authTerminated else { return }
        if case .stopped = state { return }
        backgroundGraceTask?.cancel()
        backgroundGraceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await graceSleep(config.backgroundGrace)
            } catch {
                return // foreground cancelled the grace window
            }
            await suspendAfterGrace()
        }
    }

    /// Resumes from the background. A `.ready` that survived the grace window is not
    /// trusted blindly — the process was frozen, so the socket may be silently dead —
    /// and is probed for liveness; a suspended or backing-off connection cancels any
    /// pending backoff and reconnects immediately. A connection stopped by a terminal
    /// auth rejection is not revived.
    public func foreground() {
        resume()
    }

    /// Reopens the connection now, at a reader's explicit request — the pull-to-refresh
    /// path. Identical to ``foreground()`` in what it does; separate in what it means,
    /// so a call site asking for a refresh does not have to claim a scene-phase change
    /// it did not observe. A connection stopped for a rejected identity is not revived
    /// by either.
    public func reconnectNow() {
        resume()
    }

    /// The shared body of ``foreground()`` and ``reconnectNow()``: whatever this
    /// connection is doing, get it back to `.ready` as directly as its state allows.
    private func resume() {
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        guard !authTerminated else { return }
        if case .stopped = state { return }

        switch state {
        case .ready:
            // A `.ready` that outlived a freeze is unproven; the probe confirms the
            // socket or forces a reconnect. See ``armForegroundProbe()``.
            armForegroundProbe()
        case .connecting, .authenticating:
            // A handshake frozen by backgrounding does *not* reliably resolve on its
            // own: the process could not service the socket while it was away, and the
            // peer may be gone. There is nothing to ping — an unauthenticated socket
            // proves nothing by ponging — so the deadline is re-armed at the far tighter
            // foreground bound, and a handshake that has not landed by then is retried.
            armHandshakeDeadline(generation: currentGeneration, within: config.foregroundHandshakeDeadline)
        case .stopped:
            return
        case .idle, .suspended, .backingOff:
            reconnectTask?.cancel()
            reconnectSuppressed = false
            reconnectAttempt = 0
            reconnectTask = Task { [weak self] in await self?.reconnectImmediately() }
        }
    }

    /// Releases the socket after the grace window elapsed: the app is genuinely away,
    /// so the connection is torn down and auto-reconnect suppressed until it returns.
    func suspendAfterGrace() async {
        backgroundGraceTask = nil
        guard !authTerminated, !isStopping else { return }
        if case .stopped = state { return }
        advanceGeneration()
        reconnectTask?.cancel(); reconnectTask = nil
        readTask?.cancel(); readTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        handshakeTask?.cancel(); handshakeTask = nil
        reconnectSuppressed = true
        await closeTransport()
        failInFlight(with: .notConnected)
        // A caller parked mid-handshake must fail fast like everything else, not sit
        // out the full auth timeout against a suspended connection.
        resumeAuthWaiters(.failure(RelayConnectionError.notConnected))
        authenticatedAs = nil
        state = .suspended
    }
}
