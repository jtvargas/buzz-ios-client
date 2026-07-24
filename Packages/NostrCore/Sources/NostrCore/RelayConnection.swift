import Foundation

/// One authenticated, self-healing connection to a Buzz relay.
///
/// This is the reliability core of the client: it owns a single
/// ``RelayTransport``, drives the NIP-42 handshake, publishes events and runs
/// one-shot queries against a live socket, and keeps the socket alive across
/// drops, backgrounding, and half-open failures — surfacing everything else to
/// the subscription layer above through ``inbound()``.
///
/// # Why an actor
///
/// The whole design turns on one invariant: at most one thing mutates connection
/// state at a time. A frame arriving on the read loop, a `publish` call from the
/// UI, a reconnect timer firing, and a foreground event can all land at once;
/// actor isolation serializes them so the state machine never observes a torn
/// intermediate. The transport is a separate actor, so the read loop's
/// `receive()` suspends off this actor and other work interleaves cleanly.
///
/// # Generation counter
///
/// Task cancellation alone cannot promise that a frame from a socket being torn
/// down will not be processed after a new socket has replaced it. Every socket
/// lifecycle carries a monotonically increasing generation, stamped on its read
/// loop and watchdog; any frame, error, or timer whose generation is not the
/// current one is dropped. Cheap, and airtight against a late delivery from a
/// dead socket corrupting the new one's state.
///
/// # Auth discipline
///
/// Buzz relays advertise auth unconditionally, so a REQ or EVENT sent before the
/// handshake completes only earns a wasted round trip and a `CLOSED
/// auth-required`. Every send therefore waits for ``ConnectionState/ready``. The
/// auth verdict is completed *inline* on the read loop before the next frame is
/// processed, so a frame arriving right behind the auth `OK` is never handled
/// while the connection still looks unauthenticated. A memoized failure makes a
/// waiter that arrives after a rejection fail immediately instead of suspending
/// against an event that has already come and gone.
///
/// The implementation is split across focused extensions — the read loop and
/// watchdog, the NIP-42 handshake, and the publish/query/routing surface — that
/// all share the isolated state declared here.
public actor RelayConnection {
    // MARK: - Injected collaborators

    let url: URL
    let signer: any EventSigner
    let config: RelayConnectionConfig

    /// Mints a fresh transport per socket lifecycle. Injecting a factory — rather
    /// than reusing one transport — is what lets the generation model give each
    /// socket a clean object, and lets a test vend a scripted fake per attempt.
    let makeTransport: @Sendable () async -> any RelayTransport
    /// The jitter fraction for the next backoff delay, in `0...1`. Injected so a
    /// test pins the schedule; production draws from the system CSPRNG.
    let jitter: @Sendable () -> Double
    /// The monotonic clock, injected so a test can control measured uptime for
    /// the ``ReconnectPolicy/resetAfter`` reset.
    let now: @Sendable () -> ContinuousClock.Instant
    /// Sleeps a reconnect backoff. Separated from ``sleep`` so a test can make
    /// backoff instant while gating a background-grace timer, or gate backoff to
    /// prove a foreground cancels it.
    let backoffSleep: @Sendable (Duration) async throws -> Void
    /// Sleeps the background grace window. Separated so a test can hold the app in
    /// grace and release it deterministically.
    let graceSleep: @Sendable (Duration) async throws -> Void
    /// Sleeps every other internal timer — the watchdog interval, the ping
    /// deadline, the auth watchdog, the query deadline. Defaults are large enough
    /// that none fires during a fast, unrelated test.
    let sleep: @Sendable (Duration) async throws -> Void

    // MARK: - Observable state

    public internal(set) var state: ConnectionState = .idle {
        didSet {
            guard state != oldValue else { return }
            for continuation in stateObservers.values {
                continuation.yield(state)
            }
        }
    }

    private var stateObservers: [Int: AsyncStream<ConnectionState>.Continuation] = [:]
    private var inboundObservers: [Int: AsyncStream<RelayInbound>.Continuation] = [:]
    private var nextObserverID = 0

    // MARK: - Socket lifecycle

    /// The current socket's generation. Every read loop and watchdog carries the
    /// generation it was born under; anything from a different one is stale.
    private(set) var currentGeneration = 0
    var transport: (any RelayTransport)?
    var readTask: Task<Void, Never>?
    var watchdogTask: Task<Void, Never>?
    var reconnectTask: Task<Void, Never>?
    private var backgroundGraceTask: Task<Void, Never>?
    var foregroundProbeTask: Task<Void, Never>?

    /// When the current socket last connected, for the ``ReconnectPolicy``
    /// health-based counter reset.
    var connectionEstablishedAt: ContinuousClock.Instant?
    /// Consecutive reconnect attempts since the last reset.
    var reconnectAttempt = 0

    /// Set by a client `stop()`; blocks auto-reconnect and fails waiters.
    var isStopping = false
    /// Set by a background grace teardown or a `stop()`; blocks auto-reconnect
    /// until an explicit `connect()`/`foreground()` clears it.
    var reconnectSuppressed = false
    /// Set by a terminal auth rejection; blocks auto-reconnect *and* is only
    /// cleared by an explicit `connect()`, so `foreground()` cannot revive a
    /// rejected identity.
    var authTerminated = false

    // MARK: - Authentication

    /// The id of the in-flight NIP-42 answer, so its `OK` is told apart from a
    /// publish `OK`.
    var pendingAuthEventID: String?
    /// The authenticated identity once the relay accepts the answer.
    var authenticatedAs: PublicKey?
    /// The last auth failure, held so a waiter arriving after the failure fails
    /// fast rather than suspending on a verdict that already happened. Cleared on
    /// the next challenge.
    var authFailure: RelayConnectionError?
    var authWaiters: [Int: CheckedContinuation<Void, Error>] = [:]
    var nextWaiterID = 0

    // MARK: - In-flight requests

    var pendingPublishes: [String: CheckedContinuation<Void, Error>] = [:]
    var oneShotQueries: [String: PendingQuery] = [:]
    var nextSubscriptionID = 0

    struct PendingQuery {
        let filters: [Filter]
        let continuation: CheckedContinuation<[NostrEvent], Error>
        var collected: [NostrEvent] = []
        /// Guards the single re-auth retry so a genuinely forbidden query cannot
        /// loop.
        var retriedAfterAuth = false
    }

    // MARK: - Init

    public init(
        url: URL,
        signer: any EventSigner,
        config: RelayConnectionConfig = .default,
        makeTransport: @escaping @Sendable () async -> any RelayTransport = { URLSessionTransport() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0 ... 1) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        backoffSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        graceSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.url = url
        self.signer = signer
        self.config = config
        self.makeTransport = makeTransport
        self.jitter = jitter
        self.now = now
        self.backoffSleep = backoffSleep
        self.graceSleep = graceSleep
        self.sleep = sleep
    }

    // MARK: - Observation

    /// A live feed of connection state, seeded with the current value so a new
    /// observer never misses the state it subscribed in.
    public func connectionStates() -> AsyncStream<ConnectionState> {
        let (stream, continuation) = AsyncStream.makeStream(of: ConnectionState.self)
        let id = nextObserverID
        nextObserverID += 1
        stateObservers[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeStateObserver(id) }
        }
        return stream
    }

    /// A feed of subscription frames the connection did not consume itself —
    /// events, EOSE, and CLOSED for subscriptions a consumer owns. The step-8
    /// subscription manager is the intended sole consumer.
    public func inbound() -> AsyncStream<RelayInbound> {
        let (stream, continuation) = AsyncStream.makeStream(of: RelayInbound.self)
        let id = nextObserverID
        nextObserverID += 1
        inboundObservers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeInboundObserver(id) }
        }
        return stream
    }

    private func removeStateObserver(_ id: Int) {
        stateObservers.removeValue(forKey: id)
    }

    private func removeInboundObserver(_ id: Int) {
        inboundObservers.removeValue(forKey: id)
    }

    func yieldInbound(_ frame: RelayInbound) {
        for continuation in inboundObservers.values {
            continuation.yield(frame)
        }
    }

    // MARK: - Lifecycle

    /// Opens the connection. Returns once the socket is connected; the NIP-42
    /// handshake then completes asynchronously as the relay challenges. Throws if
    /// the initial socket cannot be opened — a runtime drop after a successful
    /// open reconnects on its own instead of throwing here.
    ///
    /// An explicit call is the owner choosing to (re)start, so it clears the stop
    /// and auth-rejection latches a prior run may have set.
    public func connect() async throws {
        isStopping = false
        authTerminated = false
        reconnectSuppressed = false
        reconnectTask?.cancel()
        reconnectTask = nil
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        reconnectAttempt = 0
        connectionEstablishedAt = nil
        authFailure = nil
        try await establishConnection()
    }

    /// Arms the background grace window. If the app returns to the foreground
    /// within it, the socket is kept; otherwise the socket is released. A quick
    /// app switch therefore does not churn the connection.
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

    /// Resumes from the background. A `.ready` that survived the grace window is
    /// not trusted blindly — the process was frozen, so the socket may be silently
    /// dead — and is probed for liveness; a suspended or backing-off connection
    /// cancels any pending backoff and reconnects immediately. A connection stopped
    /// by a terminal auth rejection is not revived.
    public func foreground() {
        backgroundGraceTask?.cancel()
        backgroundGraceTask = nil
        guard !authTerminated else { return }
        if case .stopped = state { return }

        switch state {
        case .ready:
            // A `.ready` that outlived a freeze is unproven; the probe confirms the
            // socket or forces a reconnect. See ``armForegroundProbe()``.
            armForegroundProbe()
        case .connecting, .authenticating, .stopped:
            return // an in-flight handshake resolves on its own; nothing to probe
        case .idle, .suspended, .backingOff:
            reconnectTask?.cancel()
            reconnectSuppressed = false
            reconnectAttempt = 0
            reconnectTask = Task { [weak self] in await self?.reconnectImmediately() }
        }
    }

    /// Tears the connection down for good. In-flight requests and auth waiters
    /// fail, auto-reconnect is disabled, and the socket is closed. A later
    /// explicit ``connect()`` may start a fresh one.
    public func stop() async {
        isStopping = true
        reconnectSuppressed = true
        advanceGeneration()
        backgroundGraceTask?.cancel(); backgroundGraceTask = nil
        foregroundProbeTask?.cancel(); foregroundProbeTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        readTask?.cancel(); readTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        await closeTransport()
        authFailure = .stopped
        failInFlight(with: .stopped)
        resumeAuthWaiters(.failure(RelayConnectionError.stopped))
        state = .stopped(.client)
    }

    private func suspendAfterGrace() async {
        backgroundGraceTask = nil
        guard !authTerminated, !isStopping else { return }
        if case .stopped = state { return }
        advanceGeneration()
        reconnectTask?.cancel(); reconnectTask = nil
        readTask?.cancel(); readTask = nil
        watchdogTask?.cancel(); watchdogTask = nil
        reconnectSuppressed = true
        await closeTransport()
        failInFlight(with: .notConnected)
        // A caller parked mid-handshake must fail fast like everything else,
        // not sit out the full auth timeout against a suspended connection.
        resumeAuthWaiters(.failure(RelayConnectionError.notConnected))
        authenticatedAs = nil
        state = .suspended
    }

    // MARK: - Establishing a socket

    private func establishConnection() async throws {
        let generation = advanceGeneration()
        state = .connecting

        // A superseded read loop exits via the generation guard without closing
        // its socket — close the old transport here so a connect-while-live
        // never leaves the previous socket open until the peer drops it.
        if let previous = transport {
            transport = nil
            await previous.close()
        }

        let transport = await makeTransport()
        self.transport = transport

        do {
            try await transport.connect(url: url)
        } catch {
            await transport.close()
            if self.transport === transport { self.transport = nil }
            throw error
        }

        // A teardown may have landed while the connect was in flight; if so this
        // socket is already stale — abandon it rather than wiring up a read loop
        // the generation guard would only ignore.
        guard generation == currentGeneration else {
            await transport.close()
            throw RelayConnectionError.notConnected
        }

        connectionEstablishedAt = now()
        readTask = Task { [weak self] in
            await self?.readLoop(generation: generation, transport: transport)
        }
        watchdogTask = Task { [weak self] in
            await self?.runWatchdog(generation: generation, transport: transport)
        }
    }

    func reconnectImmediately() async {
        do {
            try await establishConnection()
        } catch {
            guard !reconnectSuppressed, !authTerminated, !isStopping else { return }
            await runReconnectLoop()
        }
    }

    func runReconnectLoop() async {
        while !reconnectSuppressed, !authTerminated, !isStopping {
            reconnectAttempt += 1
            state = .backingOff(attempt: reconnectAttempt)

            do {
                try await backoffSleep(config.reconnectPolicy.delay(forAttempt: reconnectAttempt, fraction: jitter()))
            } catch {
                return // cancelled by foreground/stop
            }
            guard !reconnectSuppressed, !authTerminated, !isStopping else { return }

            do {
                try await establishConnection()
                return // the read loop drives the handshake from here
            } catch {
                continue
            }
        }
    }

    @discardableResult
    func advanceGeneration() -> Int {
        currentGeneration += 1
        return currentGeneration
    }

    func closeTransport() async {
        guard let transport else { return }
        self.transport = nil
        await transport.close()
    }
}
