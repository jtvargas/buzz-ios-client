import Foundation

/// The single-relay channel a ``TargetPairingSession`` drives — the seam that lets
/// the whole protocol state machine be tested against a scripted double with no
/// socket.
public protocol PairingChannel: Sendable {
    /// Connects, completes optional NIP-42 auth, subscribes to this session's
    /// ephemeral `#p`, and returns once the relay signals EOSE — the proof that
    /// live responses can now be received (the sidecar keeps no history, so EOSE,
    /// not a sleep, is the readiness signal). Throws on connect/auth/subscription
    /// failure.
    func open() async throws

    /// Publishes a signed pairing event and returns the relay's `OK` verdict
    /// (`accepted`). Throws if the socket dropped before a verdict arrived.
    @discardableResult
    func publish(_ event: NostrEvent) async throws -> Bool

    /// A live stream of inbound `kind:24134` events delivered for this session's
    /// subscription. The consumer performs NIP-AB event validation.
    func inboundEvents() async -> AsyncStream<NostrEvent>

    /// Tears the socket down and fails anything in flight. Idempotent.
    func close() async
}

/// A purpose-built, single-use NIP-AB pairing connection over one ``RelayTransport``.
///
/// It is deliberately **not** the app's main ``RelayConnection``: that one gates
/// every send on an accepted NIP-42 handshake, which would hang forever against a
/// dedicated pairing relay that issues no challenge. This connection instead treats
/// auth as *optional* — it answers a challenge if one arrives within a short grace
/// window, and otherwise proceeds unauthenticated — so it works against both a
/// challenge-issuing main relay and a silent pairing sidecar. It also runs under a
/// throwaway ephemeral signer, never the user's identity.
///
/// No reconnect, no backfill, no watchdog: a pairing session lives for at most 120
/// seconds and a dropped socket ends it. The owning session imposes every protocol
/// deadline and calls ``close()`` on any terminal state, which resolves anything in
/// flight.
public actor PairingConnection: PairingChannel {
    // MARK: Injected

    let url: URL
    let signer: any EventSigner
    /// This session's ephemeral pubkey, the `#p` the subscription filters on.
    let ephemeralPublicKey: String
    let subscriptionID: String
    let authGrace: Duration
    let makeTransport: @Sendable () async -> any RelayTransport
    let sleep: @Sendable (Duration) async throws -> Void

    // MARK: State

    var transport: (any RelayTransport)?
    private var readTask: Task<Void, Never>?
    private var graceTask: Task<Void, Never>?
    private var isClosed = false

    /// The id of the in-flight NIP-42 answer, so its `OK` is told apart from a
    /// publish `OK`.
    var pendingAuthEventID: String?
    /// Set once any challenge is seen, so the grace timer does not proceed
    /// unauthenticated while an answer is still outstanding.
    var challengeSeen = false
    private var authResolved = false
    private var authContinuation: CheckedContinuation<Void, Error>?

    private var didSubscribe = false
    private var eoseResolved = false
    private var eoseContinuation: CheckedContinuation<Void, Error>?

    var pendingPublishes: [String: CheckedContinuation<Bool, Error>] = [:]
    private var inboundContinuation: AsyncStream<NostrEvent>.Continuation?

    // MARK: Init

    public init(
        url: URL,
        signer: any EventSigner,
        ephemeralPublicKey: String,
        subscriptionID: String = "pair-\(UInt32.random(in: .min ... .max))",
        authGrace: Duration = .seconds(3),
        makeTransport: @escaping @Sendable () async -> any RelayTransport = { URLSessionTransport() },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.url = url
        self.signer = signer
        self.ephemeralPublicKey = ephemeralPublicKey
        self.subscriptionID = subscriptionID
        self.authGrace = authGrace
        self.makeTransport = makeTransport
        self.sleep = sleep
    }

    // MARK: - PairingChannel

    public func open() async throws {
        guard !isClosed else { throw NostrPairError.connectionFailed("connection already closed") }

        let transport = await makeTransport()
        self.transport = transport
        do {
            try await transport.connect(url: url)
        } catch {
            await failClosed(NostrPairError.connectionFailed(String(describing: error)))
            throw NostrPairError.connectionFailed(String(describing: error))
        }

        startReadLoop(transport)
        try await awaitAuthPhase()
        try await subscribe(transport)
        try await awaitEOSE()
    }

    public func inboundEvents() async -> AsyncStream<NostrEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NostrEvent.self)
        inboundContinuation = continuation
        if isClosed { continuation.finish() }
        return stream
    }

    public func publish(_ event: NostrEvent) async throws -> Bool {
        guard !isClosed else { throw NostrPairError.connectionFailed("connection closed") }
        let frame = try ClientMessage.event(event).encoded()
        return try await withCheckedThrowingContinuation { continuation in
            pendingPublishes[event.id] = continuation
            Task { await transmit(frame, publishID: event.id) }
        }
    }

    public func close() async {
        await failClosed(NostrPairError.connectionFailed("connection closed"))
    }

    // MARK: - Open-phase gating

    private func awaitAuthPhase() async throws {
        if authResolved { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            authContinuation = continuation
            graceTask = Task { [weak self] in
                try? await self?.sleep(self?.authGrace ?? .seconds(3))
                await self?.graceElapsed()
            }
        }
    }

    /// The grace window closed. If no challenge ever arrived, the relay does not
    /// require auth (the sidecar case) — proceed. If a challenge is mid-flight, wait
    /// for its `OK` instead of racing past it.
    private func graceElapsed() {
        guard !authResolved, !challengeSeen, pendingAuthEventID == nil else { return }
        resolveAuth(.success(()))
    }

    func resolveAuth(_ result: Result<Void, Error>) {
        guard !authResolved else { return }
        authResolved = true
        graceTask?.cancel(); graceTask = nil
        authContinuation?.resume(with: result)
        authContinuation = nil
    }

    private func subscribe(_ transport: any RelayTransport) async throws {
        let filter = Filter(kinds: [.devicePairing], tagQueries: ["p": [ephemeralPublicKey]])
        let frame = try ClientMessage.req(subscriptionID: subscriptionID, filters: [filter]).encoded()
        do {
            try await transport.send(frame)
            didSubscribe = true
        } catch {
            throw NostrPairError.connectionFailed(String(describing: error))
        }
    }

    private func awaitEOSE() async throws {
        if eoseResolved { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            eoseContinuation = continuation
        }
    }

    func resolveEOSE(_ result: Result<Void, Error>) {
        guard !eoseResolved else { return }
        eoseResolved = true
        eoseContinuation?.resume(with: result)
        eoseContinuation = nil
    }

    // MARK: - Sending

    private func transmit(_ frame: Data, publishID: String) async {
        guard let transport else { failPublish(publishID); return }
        do {
            try await transport.send(frame)
        } catch {
            failPublish(publishID)
        }
    }

    func resolvePublish(_ eventID: String, accepted: Bool) {
        pendingPublishes.removeValue(forKey: eventID)?.resume(returning: accepted)
    }

    private func failPublish(_ eventID: String) {
        pendingPublishes.removeValue(forKey: eventID)?
            .resume(throwing: NostrPairError.connectionFailed("publish failed"))
    }

    func yieldInbound(_ event: NostrEvent) {
        inboundContinuation?.yield(event)
    }

    // MARK: - Teardown

    /// Resolves every in-flight continuation with `error`, finishes the inbound
    /// stream, and closes the socket. The single teardown path for a clean
    /// ``close()``, a socket drop, or a subscription refusal.
    func failClosed(_ error: Error) async {
        guard !isClosed else { return }
        isClosed = true
        readTask?.cancel(); readTask = nil
        graceTask?.cancel(); graceTask = nil
        resolveAuth(.failure(error))
        resolveEOSE(.failure(error))
        for continuation in pendingPublishes.values {
            continuation.resume(throwing: error)
        }
        pendingPublishes.removeAll()
        inboundContinuation?.finish()
        inboundContinuation = nil
        let transport = self.transport
        self.transport = nil
        await transport?.close()
    }

    private func startReadLoop(_ transport: any RelayTransport) {
        readTask = Task { [weak self] in
            await self?.readLoop(transport)
        }
    }
}
