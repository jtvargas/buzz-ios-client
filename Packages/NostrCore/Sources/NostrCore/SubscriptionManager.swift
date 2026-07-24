import Foundation

/// Owns the live subscriptions multiplexed over one ``RelayConnection``.
///
/// A ``RelayConnection`` deliberately knows nothing about live subscriptions: it
/// authenticates, publishes, runs one-shot queries, and surfaces every other
/// subscription frame on ``RelayConnection/inbound()``. This manager is that
/// stream's intended consumer. It turns a caller's filter into a `REQ`, routes
/// the relay's answer to the caller's ``EventSink``, keeps the subscription alive
/// across reconnects, and closes it on request.
///
/// # Two behaviours that matter most
///
/// **Batched, phase-marked delivery.** Events are never handed to the sink one at
/// a time. Backfill (a relay's stored-history replay) is buffered and flushed in
/// batches of ``SubscriptionManagerConfig/batchSize`` and once more at `EOSE`;
/// live events are coalesced on a short tick. Each flush is a single
/// ``EventSink/ingest(batch:subscription:phase:)`` call tagged
/// ``IngestPhase/backfill`` or ``IngestPhase/live``, so a several-hundred-event
/// backfill costs a couple of store round-trips rather than one per event.
///
/// **EOSE-gated replay cursor.** A subscription tracks the newest `created_at` it
/// has delivered, but that high-water mark is armed as a reconnect cursor only
/// *after the subscription's first `EOSE`*. A Buzz relay serves stored events
/// newest-first, so a socket dropped mid-backfill leaves the newest events in
/// hand and a hole beneath them; replaying from "newest seen" would step over
/// that hole forever. Before the first `EOSE`, a reconnect therefore re-runs the
/// original filter and re-fetches everything; only once a complete replay has
/// been observed is it safe to resume from `lastSeen − overlap`.
///
/// # Isolation
///
/// The manager is an actor, so frame routing, reconnect re-arming, registration,
/// and flush timers are serialized: a subscription's buffer and phase are never
/// observed mid-mutation. Its two long-lived tasks — one draining
/// ``RelayConnection/inbound()``, one watching
/// ``RelayConnection/connectionStates()`` — hop back onto the actor for every
/// frame and every state change. The implementation is split across focused
/// extensions — delivery, and subscribing — that share the isolated state here.
public actor SubscriptionManager {
    // MARK: - Injected collaborators

    let connection: RelayConnection
    let signer: any EventSigner
    let config: SubscriptionManagerConfig

    /// Sleeps the live-phase coalescing tick. Injected on the same principle as
    /// ``RelayConnection``'s timers, so a test drives a flush by hand rather than
    /// by the wall clock; production sleeps for real.
    let liveFlushSleep: @Sendable (Duration) async throws -> Void

    // MARK: - Subscription state

    /// The mutable per-subscription bookkeeping. A reference type so a flush can
    /// read-and-clear a buffer without a dictionary write-back dance around the
    /// `await` into the sink, and so a frame arriving during that await mutates
    /// the same instance rather than a stale copy. It never escapes the actor.
    final class Subscription {
        let id: SubscriptionID
        let originalFilters: [Filter]
        let sink: any EventSink

        /// `.backfill` until the current `REQ`'s `EOSE`, then `.live`. Reset to
        /// `.backfill` on every re-arm, since a fresh `REQ` replays anew.
        var phase: IngestPhase = .backfill
        /// Set at the first `EOSE` and never cleared: once a full replay has been
        /// seen, reconnects resume from the cursor rather than the raw filter.
        var cursorArmed = false
        /// The newest `created_at` delivered, the basis of the replay cursor.
        var lastSeen: Int64?

        var backfillBuffer: [NostrEvent] = []
        var liveBuffer: [NostrEvent] = []
        var liveFlushTask: Task<Void, Never>?

        /// The readiness epoch this subscription was last `REQ`ed under, so a
        /// re-arm for an epoch already served is skipped rather than doubled.
        var armedEpoch: Int?
        /// Guards the single re-open after a `CLOSED auth-required`, mirroring the
        /// connection's one-shot retry-once. Reset by a clean `EOSE`.
        var retriedAfterClose = false

        init(id: SubscriptionID, originalFilters: [Filter], sink: any EventSink) {
            self.id = id
            self.originalFilters = originalFilters
            self.sink = sink
        }
    }

    var subscriptions: [SubscriptionID: Subscription] = [:]
    private var nextSubscriptionNumber = 0

    // MARK: - Observation state

    private var started = false
    private var inboundTask: Task<Void, Never>?
    private var stateTask: Task<Void, Never>?

    /// Whether the connection is, as last observed, `ready`. Registration consults
    /// it to decide whether to arm now or leave the readiness observer to do it.
    var connectionIsReady = false
    /// Bumped on each transition into `ready`. A new epoch is a fresh socket that
    /// every live subscription must be re-`REQ`ed onto exactly once.
    var readyEpoch = 0

    /// The authenticated identity's hex pubkey, resolved from the signer once and
    /// cached — only pubkey-gated filters need it, and only the first time.
    var cachedPubkeyHex: String?

    // MARK: - Init

    public init(
        connection: RelayConnection,
        signer: any EventSigner,
        config: SubscriptionManagerConfig = .default,
        liveFlushSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connection = connection
        self.signer = signer
        self.config = config
        self.liveFlushSleep = liveFlushSleep
    }

    // MARK: - Lifecycle

    /// Begins consuming the connection's inbound and state feeds. Idempotent, and
    /// called automatically by ``register(filters:sink:)``, so a caller rarely
    /// invokes it directly. The inbound observer is attached *before* this returns
    /// so no frame yielded after start can be missed.
    public func start() async {
        guard !started else { return }
        started = true

        // Attach both observers up front. `inbound()` buffers from the moment it
        // is called, so registering it here — before any subscription is armed —
        // guarantees an event for a REQ we are about to send cannot slip past an
        // observer that is not yet listening.
        let inboundFrames = await connection.inbound()
        let states = await connection.connectionStates()

        inboundTask = Task { [weak self] in
            for await frame in inboundFrames {
                await self?.route(frame)
            }
        }
        stateTask = Task { [weak self] in
            for await state in states {
                await self?.handleReadinessChange(state)
            }
        }
    }

    /// Stops observing and drops all subscriptions without closing the underlying
    /// connection, which the manager does not own. In-flight flush timers are
    /// cancelled; the relay-side subscriptions are abandoned to the socket's
    /// teardown rather than individually `CLOSE`d, since a shutdown is typically
    /// part of tearing the whole connection down.
    public func shutdown() {
        inboundTask?.cancel(); inboundTask = nil
        stateTask?.cancel(); stateTask = nil
        for subscription in subscriptions.values {
            subscription.liveFlushTask?.cancel()
        }
        subscriptions.removeAll()
        connectionIsReady = false
        started = false
    }

    // MARK: - Registration

    /// Opens a live subscription: validates the filters, sends a `REQ`, and routes
    /// the relay's answer to `sink` until ``unsubscribe(_:)`` or a terminal
    /// `CLOSED`. The subscription survives reconnects, re-arming itself whenever
    /// the connection returns to `ready`.
    ///
    /// Throws ``SubscriptionError/kindlessFilter`` or
    /// ``SubscriptionError/pubkeyScopeRequired(_:)`` if any filter would be
    /// refused by the relay; nothing is registered in that case. A transient lack
    /// of a live socket is *not* an error — the subscription registers and arms on
    /// the next `ready`.
    @discardableResult
    public func register(filters: [Filter], sink: any EventSink) async throws -> SubscriptionID {
        try await validate(filters)

        let id = mintSubscriptionID()
        let subscription = Subscription(id: id, originalFilters: filters, sink: sink)
        subscriptions[id] = subscription

        await start()
        if connectionIsReady {
            await armSubscription(id, epoch: readyEpoch, resetCloseRetry: true)
        }
        return id
    }

    /// Closes a live subscription: sends a `CLOSE` and stops delivery. Frames that
    /// arrive for it afterwards — a straggler the relay sent before it processed
    /// the `CLOSE` — are dropped silently. Unknown ids are ignored.
    public func unsubscribe(_ id: SubscriptionID) async {
        guard let subscription = subscriptions.removeValue(forKey: id) else { return }
        subscription.liveFlushTask?.cancel()
        // Best effort: if there is no live socket the relay-side subscription is
        // already gone, and dropping it from our table is what stops delivery.
        try? await connection.send(.close(subscriptionID: id.rawValue))
    }

    /// Runs a one-shot query, forwarding straight to
    /// ``RelayConnection/query(_:timeout:)``.
    ///
    /// A one-shot is `REQ` → collect → `EOSE` → resolve → `CLOSE`: it is never
    /// replayed after a reconnect, so the connection already owns it end to end.
    /// This passthrough exists only so callers can treat the manager as the single
    /// subscription surface; it adds no bookkeeping of its own.
    public func query(_ filters: [Filter], timeout: Duration? = nil) async throws -> [NostrEvent] {
        try await connection.query(filters, timeout: timeout)
    }

    // MARK: - Id minting

    private func mintSubscriptionID() -> SubscriptionID {
        nextSubscriptionNumber += 1
        return SubscriptionID("s\(nextSubscriptionNumber)")
    }
}
