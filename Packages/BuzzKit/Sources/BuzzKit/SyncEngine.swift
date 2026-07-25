import Foundation
import NostrCore

/// The one actor that ties the whole client together: it owns the
/// ``RelayConnection``, the ``SubscriptionManager``, the ``BuzzEventStore`` and its
/// outbox, the ``WindowClient``, and the ``PresenceStore``, and drives them as a
/// single lifecycle state machine. The app layer forwards scene-phase changes and
/// nothing else; no other code reaches the socket (the BuzzKit boundary rule).
///
/// # Two state machines, one actor
///
/// The **engine state** (`stopped → starting → running → suspended`) mirrors the
/// connection's own lifecycle, so a UI can show "connecting" versus "live" without
/// knowing the transport. Underneath, each channel carries its own **sync state**
/// (`unsynced → reconciling → synced`). Every transition into `.ready` is a fresh
/// socket, so all channels reset to `unsynced` and the head is refetched — the
/// NIP-CW rule that a new connection means a new head window. Suspension resets
/// them too.
///
/// # What happens on every `.ready`
///
/// A fresh, authenticated socket triggers, in order: channel discovery (a one-shot
/// query for the relay-signed group state that does not ride the live fan-out),
/// a per-channel reconcile that closes exactly the offline gap through the window
/// client, and an outbox drain. The multiplexed live subscription — one REQ
/// carrying a content filter and a membership filter — is registered once and kept
/// alive across reconnects by the manager, re-armed with its EOSE-gated replay
/// cursor.
///
/// # Isolation and generations
///
/// Frame ingest, reconcile commits, drains, and state transitions are all
/// serialized by actor isolation. A `readyGeneration` counter guards the async
/// on-`.ready` work the way ``RelayConnection`` guards its socket: a reconcile or
/// drain from a superseded socket checks the generation and abandons its remaining
/// steps rather than committing state a newer socket has already replaced.
///
/// The implementation is split across focused extensions — the ``EventSink``
/// conformance, discovery/reconcile, and the outbox drain — that share the isolated
/// state declared here.
public actor SyncEngine {
    // MARK: - Engine state

    /// The engine's lifecycle, mirroring ``ConnectionState`` at the granularity a
    /// UI needs.
    public enum State: Sendable, Equatable {
        /// No connection; a fresh ``start()`` will open one.
        case stopped
        /// A socket is opening or (re)authenticating, or the app has just launched.
        case starting
        /// Authenticated and live: subscriptions, reconcile, and drains proceed.
        case running
        /// The app backgrounded past the grace window and the socket was released.
        case suspended
    }

    /// A channel's catch-up state on the current socket.
    public enum ChannelSync: Sendable, Equatable {
        /// Not yet reconciled on this socket. Live events ingest but the watermark
        /// holds — they may sit above an open gap.
        case unsynced
        /// A head reconcile is in flight.
        case reconciling
        /// The offline gap is closed; live flushes now advance the watermark.
        case synced
        /// The window fast path degraded, so the head was assembled from the
        /// standard WebSocket filter instead. It renders to a UI like ``synced`` —
        /// the newest history is on screen — but it is deliberately *excluded* from
        /// ``syncedChannels()``: that fallback is a single limit-bounded page with no
        /// `since`, so a gap below it may still be open, and a live flush must not
        /// advance the watermark past it (it would claim a contiguity the log does
        /// not have). A later `.ready` that reconciles through the window path — or a
        /// fresh session — closes the gap and promotes the channel to ``synced``.
        case fallbackSynced
    }

    // MARK: - Injected collaborators

    let connection: RelayConnection
    let subscriptions: SubscriptionManager
    let store: BuzzEventStore
    let presence: PresenceStore
    let windowClient: WindowClient
    let signer: any EventSigner
    let config: SyncEngineConfig

    /// The engine's notion of wall-clock "now", injected so the live content
    /// filter's `since = now − window` is a value a test can pin. Defaults to the
    /// system clock.
    let now: @Sendable () -> Date
    /// Sleeps the presence-sweep cadence. Injected on ``RelayConnection``'s
    /// principle so a test drives the sweep by hand rather than by the wall clock.
    let sleepFor: @Sendable (Duration) async throws -> Void

    // MARK: - Observable engine state

    public private(set) var state: State = .stopped {
        didSet {
            guard state != oldValue else { return }
            for continuation in stateObservers.values {
                continuation.yield(state)
            }
        }
    }

    private var stateObservers: [Int: AsyncStream<State>.Continuation] = [:]
    private var nextObserverID = 0

    // MARK: - Sync state

    /// Per-channel sync state. Absent means ``ChannelSync/unsynced`` — the reset on
    /// every `.ready` is simply clearing this map.
    var channelStates: [String: ChannelSync] = [:]

    /// Bumped on every transition into `.ready`. Long async on-ready work carries
    /// the generation it began under and abandons itself once superseded.
    var readyGeneration = 0

    /// Whether the window fast path has been withdrawn for this session. A
    /// `.degraded` window result sets it; it resets only with the engine, never
    /// persisted (NIP-CW §Degradation, per-relay-per-session).
    var windowDegraded = false

    // MARK: - Outbox drain coalescing

    /// Whether a drain is running, and whether one was requested while it ran.
    /// Together they coalesce overlapping drain requests into a single in-flight
    /// drain that re-runs once more if anything asked during it — so a `.ready`
    /// that lands mid-drain never strands a row until the next reconnect.
    var drainInFlight = false
    var drainPending = false

    // MARK: - Identity and subscription

    /// The authenticated identity's hex pubkey, resolved once at ``start()`` for
    /// the membership filter's `#p` scope.
    var selfPubkeyHex: String?
    /// The multiplexed live subscription's id, held so the engine can identify its
    /// frames if it ever needs to.
    var liveSubscription: SubscriptionID?

    // MARK: - Tasks

    private var stateObserverTask: Task<Void, Never>?
    var onReadyTask: Task<Void, Never>?
    private var sweepTask: Task<Void, Never>?
    /// Set by ``stop()``; blocks reacting to the `.stopped` the engine itself
    /// caused, and short-circuits any in-flight on-ready work.
    var isStopped = false

    // MARK: - Init

    /// Wires the engine to its collaborators. They are injected rather than built
    /// here so the app composes production instances and a test composes scripted
    /// fakes — the whole stack stays deterministic under a scripted socket and a
    /// scripted HTTP transport.
    public init(
        connection: RelayConnection,
        subscriptions: SubscriptionManager,
        store: BuzzEventStore,
        presence: PresenceStore,
        windowClient: WindowClient,
        signer: any EventSigner,
        config: SyncEngineConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepFor: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connection = connection
        self.subscriptions = subscriptions
        self.store = store
        self.presence = presence
        self.windowClient = windowClient
        self.signer = signer
        self.config = config
        self.now = now
        self.sleepFor = sleepFor
    }

    // MARK: - Observation

    /// A live feed of engine state, seeded with the current value so a new observer
    /// never misses the state it subscribed in.
    public func states() -> AsyncStream<State> {
        let (stream, continuation) = AsyncStream.makeStream(of: State.self)
        let id = nextObserverID
        nextObserverID += 1
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(id) }
        }
        return stream
    }

    /// The current sync state of a channel — ``ChannelSync/unsynced`` for any
    /// channel the engine has not reconciled on this socket.
    public func channelSyncState(_ channel: String) -> ChannelSync {
        channelStates[channel] ?? .unsynced
    }

    /// The in-memory presence/typing store the engine diverts ephemerals into.
    ///
    /// Exposed so the app can subscribe to the presence roster and per-channel
    /// typing without reaching the socket (the BuzzKit boundary rule holds — this is
    /// in-memory ephemeral state, not the connection). `nonisolated` because it hands
    /// back an immutable, `Sendable` collaborator; no actor hop is needed to read it.
    public nonisolated var presenceStore: PresenceStore { presence }

    private func removeStateObserver(_ id: Int) {
        stateObservers.removeValue(forKey: id)
    }

    // MARK: - Lifecycle

    /// Opens the connection, registers the multiplexed live subscription, and
    /// begins observing connection state. Returns once the socket is opening; the
    /// on-`.ready` work (discovery, reconcile, drain) then runs as the handshake
    /// completes. Throws only if the initial socket cannot be opened or the
    /// identity cannot be resolved.
    public func start() async throws {
        isStopped = false
        state = .starting

        let pubkey = try await signer.publicKey().hex
        selfPubkeyHex = pubkey

        // Observe connection state before connecting so no transition into `.ready`
        // is missed. The stream replays the current value on subscribe.
        let states = await connection.connectionStates()
        stateObserverTask = Task { [weak self] in
            for await connectionState in states {
                await self?.handleConnectionState(connectionState)
            }
        }

        // Register the one live REQ that carries both the content and membership
        // filters. The manager keeps it alive across reconnects; the engine never
        // re-registers it.
        liveSubscription = try await subscriptions.register(
            filters: [contentFilter(), membershipFilter(selfPubkeyHex: pubkey)],
            sink: self
        )

        startPresenceSweep()

        try await connection.connect()
    }

    /// Tears the engine down: stops observing, drops subscriptions, and stops the
    /// connection. A later ``start()`` opens a fresh one against the same store.
    public func stop() async {
        isStopped = true
        stateObserverTask?.cancel(); stateObserverTask = nil
        onReadyTask?.cancel(); onReadyTask = nil
        sweepTask?.cancel(); sweepTask = nil
        await subscriptions.shutdown()
        await connection.stop()
        channelStates.removeAll()
        state = .stopped
    }

    /// Forwards a scene-phase background to the connection, which arms its grace
    /// window. Nothing else in the app reaches the socket.
    public func enterBackground() async {
        await connection.background()
    }

    /// Forwards a scene-phase foreground to the connection, which resumes a
    /// released socket. A fresh `.ready` then re-runs discovery, reconcile, and the
    /// drain.
    public func enterForeground() async {
        await connection.foreground()
    }

    // MARK: - Connection-state handling

    /// Maps a connection transition onto the engine state machine and, on every
    /// fresh `.ready`, resets channel sync state and launches the on-ready work.
    private func handleConnectionState(_ connectionState: ConnectionState) async {
        guard !isStopped else { return }

        switch connectionState {
        case .ready:
            state = .running
            readyGeneration += 1
            let generation = readyGeneration
            // A fresh socket means a fresh head: every channel is unsynced until
            // reconcile proves otherwise (NIP-CW head-refetch rule).
            channelStates.removeAll()
            onReadyTask?.cancel()
            onReadyTask = Task { [weak self] in await self?.onReady(generation: generation) }

        case .suspended:
            state = .suspended
            channelStates.removeAll()
            onReadyTask?.cancel(); onReadyTask = nil

        case let .stopped(termination):
            // A terminal auth rejection stops the connection on its own; mirror it.
            if case .authRejected = termination { onReadyTask?.cancel(); onReadyTask = nil }
            state = .stopped

        case .idle, .connecting, .authenticating, .backingOff:
            state = .starting
        }
    }

    // MARK: - Sync-state helpers

    /// Records a channel's sync state, dropping the entry when it returns to
    /// unsynced so the map only ever holds channels in flight or caught up.
    func setChannelState(_ channel: String, _ syncState: ChannelSync) {
        if syncState == .unsynced {
            channelStates.removeValue(forKey: channel)
        } else {
            channelStates[channel] = syncState
        }
    }

    /// The channels whose live flushes may advance the watermark (rule 4): only
    /// those in ``ChannelSync/synced``, whose gap the window reconcile proved
    /// closed. ``ChannelSync/fallbackSynced`` is intentionally absent — its head was
    /// assembled over a possibly-open gap, so its watermark must hold.
    func syncedChannels() -> Set<String> {
        Set(channelStates.compactMap { $0.value == .synced ? $0.key : nil })
    }

    // MARK: - Filters

    /// The live content filter: the Buzz message and overlay kinds, reaching back a
    /// small window so the connect gap drops nothing. Deep history is the window
    /// reconcile's job.
    private func contentFilter() -> Filter {
        Filter(
            kinds: [
                .channelMessage, .reaction, .deletion, .groupDeleteEvent,
                .richMessage, .messageEdit, .metadata, .presence, .typing,
            ],
            since: Int64(now().timeIntervalSince1970) - Int64(config.liveSinceWindow)
        )
    }

    /// The membership filter: relay-signed add/remove notifications scoped to the
    /// authenticated identity, as the relay requires for these p-gated kinds.
    private func membershipFilter(selfPubkeyHex: String) -> Filter {
        Filter(
            kinds: [.memberAdded, .memberRemoved],
            tagQueries: ["p": [selfPubkeyHex]]
        )
    }

    // MARK: - Presence sweep

    /// Drives ``PresenceStore/sweep()`` on the configured cadence until the engine
    /// stops. Injected sleep keeps it deterministic.
    private func startPresenceSweep() {
        let sleepFor = sleepFor
        let interval = config.presenceSweepInterval
        let presence = presence
        sweepTask?.cancel()
        sweepTask = Task {
            while !Task.isCancelled {
                do {
                    try await sleepFor(interval)
                } catch {
                    return
                }
                await presence.sweep()
            }
        }
    }
}
