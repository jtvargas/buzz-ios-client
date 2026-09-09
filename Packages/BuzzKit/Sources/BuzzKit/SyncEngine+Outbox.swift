import Foundation
import NostrCore

/// The outbox drain: sending queued messages, mapping the relay's verdict through
/// the store's disposition policy, and the coalescing that keeps overlapping drain
/// requests from stranding a row.
extension SyncEngine {
    /// Signs and queues a message, then drains — the app's send path. The event id
    /// exists the moment it is signed, so the timeline renders the pending send
    /// optimistically and the same row simply changes state on confirmation. The
    /// drain sends it now if the socket is live; otherwise it waits for the next
    /// `.ready`, and the queued row survives a relaunch.
    @discardableResult
    public func enqueue(
        kind: EventKind = .channelMessage,
        content: String,
        in channel: String,
        tags: [[String]] = [],
        maxContentBytes: Int = OutboxPolicy.maxContentBytes
    ) async throws -> OutboxEntry {
        let entry = try await store.enqueue(
            kind: kind,
            content: content,
            in: channel,
            tags: tags,
            with: signer,
            maxContentBytes: maxContentBytes
        )
        await drainOutbox()
        return entry
    }

    /// Resumes HTTP media uploads immediately, then drains relay-bound rows when
    /// the engine is running. Otherwise the row waits for the next `.ready` — and this
    /// asks for that `.ready` now rather than whenever the connection's own schedule
    /// reaches it. See ``nudgeConnection()``.
    public func drainOutbox() async {
        await resumeMediaUploads()
        guard state == .running else {
            await nudgeConnection()
            return
        }
        await requestDrain(generation: readyGeneration)
    }

    /// Asks the connection to reopen now, because somebody just tried to send.
    ///
    /// Somebody pressing send is the strongest statement of intent this engine
    /// receives, and it was the only one that never reached the socket: a row enqueued
    /// while the connection was backing off simply waited for the next `.ready`, which
    /// the connection's own schedule puts up to ``ReconnectPolicy/cap`` — thirty
    /// seconds — away. ``RelayConnection/reconnectNow()`` cancels that sleep, and is
    /// already what pull-to-refresh calls; this gives the send path the same lever.
    ///
    /// Two deliberate limits.
    ///
    /// **Foreground only.** A backgrounded app released its socket on purpose
    /// (``RelayConnectionConfig/backgroundGrace``); reviving it for a queued row would
    /// spend battery to beat a deadline nobody is watching. The next foreground
    /// reconnects anyway.
    ///
    /// **Rate-limited.** A nudge arriving while the connection is still backing off
    /// resets its attempt counter, so an ungated one would let a run of sends retry a
    /// dead network on a tight loop for as long as somebody kept typing. See
    /// ``SyncEngineConfig/connectionNudgeInterval``.
    func nudgeConnection() async {
        guard isForeground, !isStopped else { return }
        let moment = now()
        if let last = lastConnectionNudge,
           moment.timeIntervalSince(last) < config.connectionNudgeInterval {
            return
        }
        lastConnectionNudge = moment
        await connection.reconnectNow()
    }

    /// Returns a failed send to the queue and drains, so an explicit human retry is
    /// a fresh start rather than a continuation of the backoff that gave up.
    public func retry(_ eventID: String) async throws {
        if try await store.retryOutboxMedia(eventID) {
            scheduleMediaPump(eventID: eventID, retryIfRunning: true)
            return
        }
        try await store.retry(eventID)
        await drainOutbox()
    }

    /// Drops a queued send without delivering it — the "delete" action on an own
    /// pending or failed row. Best-effort: if the relay has already accepted a
    /// `sending` row the log holds it and it renders sent, which is the honest
    /// outcome; there is nothing left to unsend.
    public func discard(_ eventID: String) async throws {
        let removable = try await store.discard(eventID)
        guard let mediaStagingStore else { return }
        for key in removable { try? mediaStagingStore.remove(key) }
    }

    /// Requests a drain, coalescing with any in-flight one. If a drain is already
    /// running, this records that another pass is wanted and returns; the running
    /// drain re-runs once more when it finishes. That single-drain-at-a-time
    /// discipline stops two passes from double-sending a row, while the re-run
    /// guarantees a request that arrived mid-drain (a fresh `.ready`) is still
    /// served.
    func requestDrain(generation: Int) async {
        guard !drainInFlight else {
            drainPending = true
            return
        }
        drainInFlight = true
        defer { drainInFlight = false }
        repeat {
            drainPending = false
            await performDrain(generation: readyGeneration)
        } while drainPending && state == .running && !isStopped
        _ = generation
    }

    /// Sends every drainable row oldest-first: `pending`, `sending` (outcome
    /// unknown, resent because the relay dedupes by id), and `awaitingReauth`
    /// (resent once the connection re-authenticates and returns to `.ready`).
    /// `awaitingMedia` remains held for its upload pump; `failed` remains held for
    /// an explicit retry.
    private func performDrain(generation: Int) async {
        guard state == .running, !isStopped else { return }
        let entries = (try? await store.pendingSends()) ?? []
        for entry in entries {
            guard generation == readyGeneration, state == .running, !isStopped else { return }
            await send(entry)
        }
    }

    // MARK: - One send

    /// Hands one queued send to the relay and applies the outcome. Success (an
    /// `OK true`, or a `duplicate:` the connection already treats as success) moves
    /// it into the log; a rejection routes through the store's disposition policy; a
    /// connection loss leaves it `sending` for the next drain.
    private func send(_ entry: OutboxEntry) async {
        do {
            try await store.markSending(entry.event.id)
            try await connection.publish(entry.event)
            try await store.confirmSent(entry.event)
            // After the confirm and not before it: a subscriber is told the send landed,
            // which is only true once the row has moved into the log.
            publishSentConfirmation(entry.event)
        } catch let error as RelayConnectionError {
            await handlePublishFailure(error, entry: entry)
        } catch {
            // A store-side failure (mark/confirm) leaves the row where it is; the
            // relay dedupes, so the next drain resends and confirms safely.
        }
    }

    /// Maps a publish failure onto the outbox.
    private func handlePublishFailure(_ error: RelayConnectionError, entry: OutboxEntry) async {
        switch error {
        case let .publishRejected(reason):
            let resolution = try? await store.resolve(reason, for: entry.event.id, with: signer)
            if case let .resigned(newID)? = resolution {
                // The relay's ±15-minute gate rejected a stale timestamp; the store
                // re-signed under a fresh one. Resend the new row immediately — its
                // fresh timestamp is self-limiting, so this cannot loop.
                if let fresh = try? await store.entry(id: newID) {
                    await send(fresh)
                }
            }
            if case .failed? = resolution {
                // A terminal write refusal is often the first signal that an
                // already-open screen lost access. Reconcile its directory state
                // promptly so the UI becomes read-only.
                requestDirectoryRefresh()
            }
            // .confirmed / .awaitingReauth / .failed / .exhausted / .retrying are
            // already recorded by the store; the timing (redrain, re-auth) is the
            // engine's, and a fresh `.ready` drives it.

        case .connectionLost, .timedOut:
            // Outcome unknown: the row stays `sending` and the next drain resends it.
            // A publish that got no answer is also the earliest evidence available that
            // the socket is dead — earlier than the idle watchdog, which tolerates
            // `pingInterval + pingDeadline` of silence before it suspects anything — so
            // it drives the reconnect rather than waiting for one. This is the half of
            // the send-side nudge that covers a socket which still *looks* alive: a
            // reader cannot tell, so the failed send tells us instead.
            await nudgeConnection()

        case .notConnected, .stopped, .duplicatePublish:
            // Outcome unknown or transient, and none of them want the socket revived:
            // `notConnected` is the deliberate background release, `stopped` a sign-out,
            // and `duplicatePublish` means another in-flight publish already owns this
            // id. The row stays `sending` and the next drain resends it.
            break

        case .authenticationFailed, .authenticationRejected, .subscriptionClosed:
            // Not reachable from a publish, but exhaustively handled rather than
            // silently defaulted.
            break
        }
    }
}
