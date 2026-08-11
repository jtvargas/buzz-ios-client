import Foundation
import NostrCore

/// Whether the signed channel directory is still being checked, has supplied a
/// complete authoritative snapshot, or failed while the last safe snapshot stays
/// mounted.
public enum ChannelDirectoryStatus: Sendable, Equatable {
    case checking
    case authoritative
    case cachedFallback
}

struct ChannelDirectoryRefreshResult: Sendable {
    /// The channels the sidebar may draw: `channel_access.state = .active`. Wider than
    /// ``joined`` — the relay serves every open channel to any key, so this includes
    /// channels nobody has joined.
    let channels: Set<String>
    /// The channels whose relay-signed roster names this identity, and the only ones
    /// that earn a standing subscription and a head reconcile. See
    /// ``SyncEngine/liveChannels(joined:)``.
    let joined: Set<String>
    let status: ChannelDirectoryStatus
}

/// Keeps the directory client's existential-backed collaborators behind one
/// reference in the engine's stored state.
final class ChannelDirectoryContext: @unchecked Sendable {
    let client: any ChannelDirectoryFetching
    var refreshGeneration = 0
    var refreshInFlight = false
    var refreshPending = false
    var refreshTask: Task<Void, Never>?
    var attemptTask: Task<ChannelDirectoryRefreshResult, Never>?
    var status: ChannelDirectoryStatus = .checking
    var isForeground = true
    var backstopGeneration = 0
    /// Whether the last completed attempt was refused because this key is not a member of
    /// a closed relay. Separate from ``status`` because the two answer different
    /// questions: `status` says whether what is mounted is authoritative, and a running
    /// workspace treats every failure alike so its sidebar survives one. This says *why*,
    /// and only the identity gate asks — see ``SyncEngine/directoryRefusedMembership``.
    var refusedMembership = false

    init(client: any ChannelDirectoryFetching) {
        self.client = client
    }
}

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
/// reconciliation of the standing per-channel content subscriptions against the
/// discovered/known channel list, a per-channel reconcile that closes exactly the
/// offline gap through the window client, and an outbox drain.
///
/// # Two live-subscription tiers
///
/// Live traffic arrives on two kinds of standing subscription, split by the relay's
/// scoping rule (a REQ is channel-scoped only when *every* filter carries `#h`):
///
/// - **One global REQ**, registered once at ``start()`` and kept alive across
///   reconnects by the manager: a `#h`-less content filter (profile metadata and
///   workspace presence) multiplexed with the membership filter (`#p`-scoped
///   add/remove notifications). Channel-scoped kinds are deliberately absent — a
///   global REQ never receives them (see ``contentFilter()``).
/// - **One standing per-channel content REQ per joined channel**, each a single
///   `#h`-scoped filter carrying that channel's message/overlay/reaction/deletion
///   and typing kinds. These are the only live path for channel traffic; the set is
///   reconciled on every discovery pass and on membership changes.
///
/// Every standing subscription is re-armed with its EOSE-gated replay cursor after a
/// reconnect.
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
    let directoryContext: ChannelDirectoryContext?
    let signer: any EventSigner
    let config: SyncEngineConfig
    let mediaUploader: (any MediaUploading)?
    let mediaBaseURL: URL?
    let mediaStagingStore: MediaStagingStore?

    /// The engine's notion of wall-clock "now", injected so the live content
    /// filter's `since = now − window` is a value a test can pin. Defaults to the
    /// system clock.
    let now: @Sendable () -> Date
    /// Sleeps the presence-sweep cadence. Injected on ``RelayConnection``'s
    /// principle so a test drives the sweep by hand rather than by the wall clock.
    let sleepFor: @Sendable (Duration) async throws -> Void
    var directoryClient: (any ChannelDirectoryFetching)? { directoryContext?.client }

    /// Whether the relay has refused this identity outright: it is closed and this key is
    /// not a member of it.
    ///
    /// Meaningful only once a directory attempt has completed, which after ``start()``
    /// returns it always has — `start()` awaits the first one. Read by the identity gate,
    /// where somebody is watching a form they just filled in and "connecting…" for ever is
    /// the wrong answer to give them; a *running* workspace ignores it and keeps its last
    /// good sidebar, which is what ``ChannelDirectoryStatus/cachedFallback`` is for.
    public var directoryRefusedMembership: Bool { directoryContext?.refusedMembership ?? false }

    var directoryRefreshGeneration: Int {
        get { directoryContext?.refreshGeneration ?? 0 }
        set { directoryContext?.refreshGeneration = newValue }
    }
    var directoryRefreshInFlight: Bool {
        get { directoryContext?.refreshInFlight ?? false }
        set { directoryContext?.refreshInFlight = newValue }
    }
    var directoryRefreshPending: Bool {
        get { directoryContext?.refreshPending ?? false }
        set { directoryContext?.refreshPending = newValue }
    }
    var isForeground: Bool {
        get { directoryContext?.isForeground ?? true }
        set { directoryContext?.isForeground = newValue }
    }
    var directoryBackstopGeneration: Int {
        get { directoryContext?.backstopGeneration ?? 0 }
        set { directoryContext?.backstopGeneration = newValue }
    }

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
    var directoryStatusObservers: [Int: AsyncStream<ChannelDirectoryStatus>.Continuation] = [:]
    private var nextDirectoryStatusObserverID = 0
    private var liveMessageObservers: [Int: AsyncStream<[String]>.Continuation] = [:]
    private var nextLiveMessageObserverID = 0

    // MARK: - Sync state

    /// Per-channel sync state. Absent means ``ChannelSync/unsynced`` — the reset on
    /// every `.ready` is simply clearing this map.
    var channelStates: [String: ChannelSync] = [:]

    /// Bumped on every transition into `.ready`. Long async on-ready work carries
    /// the generation it began under and abandons itself once superseded.
    var readyGeneration = 0

    /// When the current socket's thread sweep began, and which generation that was.
    ///
    /// The brake on ``settleThreadSweep(generation:)``: a root already swept at or after
    /// `startedAt` is skipped, so the repeat passes a session makes — foreground,
    /// membership change, CLOSED recovery, pull-refresh — cost nothing on the wire once the
    /// horizon is covered, while a fresh socket re-arms the whole sweep. Held here rather
    /// than written by the connection state machine because `readyGeneration` already
    /// changes exactly when the socket does.
    var sweepEpoch: (generation: Int, startedAt: Int64)?

    /// Whether the window fast path has been withdrawn for this session. A
    /// `.degraded` window result sets it; never persisted (NIP-CW §Degradation,
    /// per-relay-per-session).
    ///
    /// Re-armed at the top of every ``SyncEngine/onReady(generation:)`` — a fresh
    /// socket is a fresh session, so the fast path is probed again. It used to be
    /// set once and never cleared anywhere in the process, which meant a single
    /// transport blip on one page of one channel downgraded *every* channel to the
    /// one-shot ``SyncEngine/fallbackAssemble(_:generation:)`` (a single
    /// ``SyncEngineConfig/windowPageLimit`` page, no cursor) for the rest of the
    /// app's run — and each of those channels then rendered as caught up over a gap
    /// nothing would go back for.
    var windowDegraded = false

    /// Where on-demand scrollback has paged to in each channel: the relay's own
    /// `next_cursor` from the last page ``SyncEngine/loadOlderHistory(channel:before:)``
    /// fetched.
    ///
    /// The chain is the relay's, not ours: only a cursor the relay minted describes
    /// a position in *its* `(created_at DESC, id ASC)` order exactly, and following
    /// it is what makes paging older provably gap-free. A locally derived cursor
    /// seeds the first page and nothing after it — see `SyncEngine+History.swift`.
    var historyCursors: [String: WindowCursor] = [:]

    // MARK: - Outbox drain coalescing

    /// Whether a drain is running, and whether one was requested while it ran.
    /// Together they coalesce overlapping drain requests into a single in-flight
    /// drain that re-runs once more if anything asked during it — so a `.ready`
    /// that lands mid-drain never strands a row until the next reconnect.
    var drainInFlight = false
    var drainPending = false

    /// When a send last asked the connection to reopen, so a run of sends cannot
    /// restart the handshake faster than it can complete. See
    /// ``SyncEngineConfig/connectionNudgeInterval``.
    var lastConnectionNudge: Date?

    /// Event ids whose media pumps are already running. Mount, drain, and enqueue
    /// may all discover the same held row; only one pump may own it at a time.
    var mediaPumpsInFlight: Set<String> = []
    /// Explicit retries that arrived while the old pump was still unwinding.
    var mediaPumpRetriesPending: Set<String> = []

    // MARK: - Identity and subscription

    /// The authenticated identity's hex pubkey, resolved once at ``start()`` for
    /// the membership filter's `#p` scope.
    var selfPubkeyHex: String?
    /// The global live subscription's id (the narrowed content filter + membership
    /// filter REQ), held so the engine can identify its frames if it ever needs to.
    var liveSubscription: SubscriptionID?
    /// The standing per-channel content subscriptions, keyed by channel id — one REQ
    /// per joined channel carrying that channel's message/overlay/reaction/typing
    /// kinds scoped by `#h` (``contentFilter(forChannel:)``). This is the only live
    /// path for channel-scoped traffic: the relay never fans channel events out to
    /// the `#h`-less global REQ (see ``contentFilter()``). The set is reconciled
    /// against the discovered/known channel list on every `.ready` and mutated on
    /// membership add/remove; one entry per channel keeps registration idempotent.
    /// Persisted across reconnects (the ``SubscriptionManager`` re-arms them), cleared
    /// only in ``stop()``.
    var channelContentSubscriptions: [String: SubscriptionID] = [:]

    /// The channel the reader has on screen, as last reported by the app through
    /// ``setActiveChannel(_:)``.
    ///
    /// Held rather than just forwarded so that a channel opened *before* its standing
    /// subscription exists still becomes the re-arm priority the moment
    /// ``subscribeChannelContent(_:)`` registers one. Ordering only — see
    /// ``setActiveChannel(_:)``.
    var activeChannel: String?

    /// The six channels or threads this identity used most recently, newest first.
    /// Loaded before the socket opens and written on every visible-conversation change, so
    /// both reconnect and a killed-app restart can spend their first work where the reader
    /// is most likely to return.
    var recentConversationDestinations: [RecentConversationDestination] = []

    /// The ready generation whose direct recent-thread queries have already run. Directory
    /// refreshes may repeat within one socket; warming the same six roots every minute would
    /// turn a launch priority into permanent background traffic.
    var recentRecoveryGeneration: Int?

    // MARK: - Tasks

    private var stateObserverTask: Task<Void, Never>?
    var onReadyTask: Task<Void, Never>?
    /// Whether ``onReady(generation:)`` is still running. ``onReadyTask`` cannot answer
    /// this — set on every `.ready` and never cleared, it is almost always a *completed*
    /// task — and ``refresh()`` must not start a second catch-up beside a live one: two
    /// concurrent reconciles of a channel race on its watermark.
    var readyWorkInFlight = false
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
        mediaUploader: (any MediaUploading)? = nil,
        mediaBaseURL: URL? = nil,
        mediaStagingStore: MediaStagingStore? = nil,
        config: SyncEngineConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepFor: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connection = connection
        self.subscriptions = subscriptions
        self.store = store
        self.presence = presence
        self.windowClient = windowClient
        directoryContext = nil
        self.signer = signer
        self.mediaUploader = mediaUploader
        self.mediaBaseURL = mediaBaseURL
        self.mediaStagingStore = mediaStagingStore
        self.config = config
        self.now = now
        self.sleepFor = sleepFor
    }

    /// Production initializer with a relay-authoritative channel directory.
    public init(
        connection: RelayConnection,
        subscriptions: SubscriptionManager,
        store: BuzzEventStore,
        presence: PresenceStore,
        windowClient: WindowClient,
        directoryClient: AnyChannelDirectoryFetcher,
        signer: any EventSigner,
        mediaUploader: (any MediaUploading)? = nil,
        mediaBaseURL: URL? = nil,
        mediaStagingStore: MediaStagingStore? = nil,
        config: SyncEngineConfig = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        sleepFor: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.connection = connection
        self.subscriptions = subscriptions
        self.store = store
        self.presence = presence
        self.windowClient = windowClient
        directoryContext = ChannelDirectoryContext(client: directoryClient)
        self.signer = signer
        self.mediaUploader = mediaUploader
        self.mediaBaseURL = mediaBaseURL
        self.mediaStagingStore = mediaStagingStore
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

    /// A live feed of directory authority, seeded with the current value so the
    /// app can choose its launch or recovery surface without a transient default.
    public func channelDirectoryStatuses() -> AsyncStream<ChannelDirectoryStatus> {
        let (stream, continuation) = AsyncStream.makeStream(of: ChannelDirectoryStatus.self)
        let id = nextDirectoryStatusObserverID
        nextDirectoryStatusObserverID += 1
        directoryStatusObservers[id] = continuation
        continuation.yield(directoryContext?.status ?? .authoritative)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeDirectoryStatusObserver(id) }
        }
        return stream
    }

    /// IDs inserted from the standing subscription after its stored-event boundary.
    /// Backfill and reconciliation never enter this stream, which makes it the app's
    /// authoritative seam for foreground-only new-message presentation.
    public func liveMessageInsertions() -> AsyncStream<[String]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [String].self)
        let id = nextLiveMessageObserverID
        nextLiveMessageObserverID += 1
        liveMessageObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLiveMessageObserver(id) }
        }
        return stream
    }

    func publishLiveMessageInsertions(_ eventIDs: [String]) {
        guard !eventIDs.isEmpty else { return }
        for continuation in liveMessageObservers.values {
            continuation.yield(eventIDs)
        }
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

    private func removeDirectoryStatusObserver(_ id: Int) {
        directoryStatusObservers.removeValue(forKey: id)
    }

    private func removeLiveMessageObserver(_ id: Int) {
        liveMessageObservers.removeValue(forKey: id)
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
        recentConversationDestinations =
            (try? await store.recentConversationDestinations(identity: pubkey)) ?? []
        recentRecoveryGeneration = nil
        // Access becomes authoritative only when this engine has a directory
        // client capable of immediately revalidating the one-time offline seed.
        // Package harnesses that intentionally exercise the legacy discovery
        // path must not opt into the access-filtered roster accidentally.
        if directoryClient != nil {
            try await store.seedChannelAccessIfNeeded(identity: pubkey)
        }

        // Observe connection state before connecting so no transition into `.ready`
        // is missed. The stream replays the current value on subscribe.
        let states = await connection.connectionStates()
        stateObserverTask = Task { [weak self] in
            for await connectionState in states {
                await self?.handleConnectionState(connectionState)
            }
        }

        // Register the one global REQ carrying the live presence filter, the
        // profile-metadata filter (no `since` — a profile is written once, so a live
        // window matches nothing), the agent directory, the membership filter, and the
        // read-state filter. All of them are
        // `#h`-less, so the whole REQ is global — which is exactly what these kinds need
        // (read state is channel-less user data the relay fans out globally). Channel-
        // scoped traffic rides the per-channel standing subs, reconciled on `.ready`
        // after discovery. The manager keeps this REQ alive across reconnects; the
        // engine never re-registers it.
        liveSubscription = try await subscriptions.register(
            filters: [
                contentFilter(),
                profileFilter(),
                agentDirectoryFilter(),
                membershipFilter(selfPubkeyHex: pubkey),
                readStateFilter(selfPubkeyHex: pubkey),
                channelMutesFilter(selfPubkeyHex: pubkey),
                remindersFilter(selfPubkeyHex: pubkey),
            ],
            sink: self
        )

        startPresenceSweep()
        if directoryClient != nil {
            startDirectoryBackstop()
        }

        if directoryContext != nil {
            // The socket and signed HTTP directory are independent transports.
            // Start both now, but only the directory's first definitive result is
            // a launch gate. A failed initial socket enters automatic reconnect.
            let connectionStart = Task { [connection] in
                do {
                    try await connection.connect()
                } catch {
                    await connection.reconnectNow()
                }
            }
            _ = await requestDirectoryRefreshAndWait()
            await connectionStart.value
        } else {
            try await connection.connect()
        }
    }

    /// Tears the engine down: stops observing, drops subscriptions, and stops the
    /// connection. A later ``start()`` opens a fresh one against the same store.
    public func stop() async {
        isStopped = true
        stateObserverTask?.cancel(); stateObserverTask = nil
        onReadyTask?.cancel(); onReadyTask = nil
        readyWorkInFlight = false
        directoryContext?.refreshTask?.cancel()
        directoryContext?.refreshTask = nil
        directoryContext?.attemptTask?.cancel()
        directoryContext?.attemptTask = nil
        directoryContext?.refreshInFlight = false
        directoryContext?.refreshPending = false
        sweepTask?.cancel(); sweepTask = nil
        await subscriptions.shutdown()
        await connection.stop()
        channelStates.removeAll()
        // `shutdown()` dropped every registered subscription; forget the per-channel
        // content-subscription ids so a later reopen re-registers cleanly rather than
        // believing a channel is still subscribed.
        channelContentSubscriptions.removeAll()
        // A scrollback cursor is a position in a store this engine may not be pointed
        // at again — signing out replaces the identity and the database under it. Keeping
        // one would seed the next session's paging below history it no longer holds.
        historyCursors.removeAll()
        // Named an id in the table just cleared; a later session re-reports whatever
        // is on screen then.
        activeChannel = nil
        recentConversationDestinations.removeAll()
        recentRecoveryGeneration = nil
        state = .stopped
    }

    /// Forwards a scene-phase background to the connection, which arms its grace
    /// window. Nothing else in the app reaches the socket.
    public func enterBackground() async {
        isForeground = false
        directoryBackstopGeneration += 1
        await connection.background()
    }

    /// Forwards a scene-phase foreground to the connection, which resumes a
    /// released socket. A fresh `.ready` then re-runs discovery, reconcile, and the
    /// drain.
    public func enterForeground() async {
        isForeground = true
        startDirectoryBackstop()
        await connection.foreground()
        requestDirectoryRefresh()
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
            // The reader's own queued sends go first, ahead of the whole catch-up the
            // on-ready pass runs below. A publish needs authentication and nothing else
            // — not the directory, not the subscriptions, not a head window — so making
            // one wait on any of them is a dependency this path does not actually have.
            //
            // It is also the only ordering that survives a directory fetch that does not
            // answer: the authoritative pass reaches its own drain only *after* that
            // fetch resolves, so a relay too slow or too broken to serve it today leaves
            // a queued row sitting until the next reconnect. Draining here is
            // independent of it entirely.
            //
            // Additive rather than a move — ``requestDrain(generation:)`` coalesces, so
            // the drain at the end of the pass costs nothing and still serves anything
            // queued *while* the pass was running.
            Task { [weak self] in await self?.requestDrain(generation: generation) }
            // A fresh socket means a fresh head: every channel is unsynced until
            // reconcile proves otherwise (NIP-CW head-refetch rule).
            channelStates.removeAll()
            onReadyTask?.cancel()
            readyWorkInFlight = true
            if directoryContext == nil {
                onReadyTask = Task { [weak self] in await self?.onReady(generation: generation) }
            } else {
                onReadyTask = Task { [weak self] in
                    await self?.onReadyAuthoritative(generation: generation)
                }
            }

        case .suspended:
            state = .suspended
            channelStates.removeAll()
            onReadyTask?.cancel(); onReadyTask = nil
            readyWorkInFlight = false

        case let .stopped(termination):
            // A terminal auth rejection stops the connection on its own; mirror it.
            if case .authRejected = termination {
                onReadyTask?.cancel(); onReadyTask = nil; readyWorkInFlight = false
            }
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

    /// A foreground-only safety net for lifecycle changes whose best-effort
    /// notifications were missed. Pull, reconnect, foreground, membership, and
    /// CLOSED all trigger sooner; this merely bounds the stale interval.
    private func startDirectoryBackstop() {
        guard directoryClient != nil, isForeground, !isStopped else { return }
        directoryBackstopGeneration += 1
        let generation = directoryBackstopGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            await self?.directoryBackstopFired(generation: generation)
        }
    }

    private func directoryBackstopFired(generation: Int) {
        guard generation == directoryBackstopGeneration,
              isForeground,
              !isStopped
        else { return }
        requestDirectoryRefresh()
        startDirectoryBackstop()
    }
}
