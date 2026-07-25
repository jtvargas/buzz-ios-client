import Foundation

/// The target-side NIP-AB pairing state machine: it generates the ephemeral
/// keypair, derives the SAS and transcript binding, drives a ``PairingChannel``,
/// enforces dual consent before ever touching the payload, and wipes all secret
/// material on every terminal state.
///
/// # Security posture (NIP-AB §Security Considerations, and the hardening this
/// build commits to)
///
/// - The payload ciphertext is **buffered, not decrypted**, until *both* the
///   transcript hash verifies *and* the user confirms the SAS — the strongest
///   dual-consent discipline the spec describes.
/// - Every inbound event is validated (id+signature, `p`-tag binding, expected
///   peer, content-length bounds) and de-duplicated by id; anything off-spec is
///   silently discarded, never answered, so the relay cannot probe session state.
/// - `complete(true)` is sent only *after* the app reports a durable import.
/// - On any terminal state — success, failure, cancellation, timeout — the
///   ephemeral key, session secret, conversation key, and any buffered ciphertext
///   are zeroed/dropped.
///
/// The session is an actor; its phase is observed through ``phases()``. All
/// deadlines (30 s per step, 120 s per session) and the socket are injected or
/// owned here, so the whole machine is deterministic under a scripted channel.
public actor TargetPairingSession {
    // MARK: Injected

    let uri: NostrPairURI
    let handler: any PairingPayloadHandler
    private let makeConnection: @Sendable (URL, any EventSigner, String) -> any PairingChannel
    private let stepTimeout: Duration
    private let sessionTimeout: Duration
    let sleep: @Sendable (Duration) async throws -> Void

    // MARK: Identity & derived crypto

    private var targetPrivateKey: PrivateKey?
    /// The target's ephemeral x-only pubkey — the `#p` the source addresses, and
    /// the value inbound events must carry.
    let targetPublicKey: PublicKey
    private var ephemeralSigner: (any EventSigner)?
    private let sourcePublicKey: PublicKey

    private var sessionSecret: Data
    private var conversationKey: Data
    let sessionID: Data
    private var sasInputBytes: Data
    private var expectedTranscriptHash: Data

    /// The six-digit SAS the user compares. Derived at init and stable for the
    /// session.
    public let sasCode: String

    // MARK: Protocol state

    enum InternalState: Equatable {
        case idle
        case connecting
        case awaitingSasConfirm
        case awaitingConfirmation
        case transferring
        case terminal

        var isTerminal: Bool { self == .terminal }
    }

    var internalState: InternalState = .idle
    var transcriptVerified = false
    var userConfirmed = false
    /// The raw NIP-44 ciphertext of the payload event, buffered undecrypted until
    /// dual consent (the memo's "buffer raw ciphertext" discipline).
    var bufferedPayloadCiphertext: String?
    /// Ids of every event already processed this session — idempotent duplicate
    /// delivery handling (NIP-AB §Duplicate Event Handling).
    var processedEventIDs: Set<String> = []

    private(set) var phase: TargetPairingPhase = .idle {
        didSet {
            guard phase != oldValue else { return }
            for continuation in phaseObservers.values { continuation.yield(phase) }
        }
    }

    private var phaseObservers: [Int: AsyncStream<TargetPairingPhase>.Continuation] = [:]
    private var nextObserverID = 0

    var connection: (any PairingChannel)?
    var inboundTask: Task<Void, Never>?
    private var stepDeadlineTask: Task<Void, Never>?
    private var sessionDeadlineTask: Task<Void, Never>?

    // MARK: - Init

    public init(
        uri: NostrPairURI,
        handler: any PairingPayloadHandler,
        targetKey: PrivateKey? = nil,
        makeConnection: @escaping @Sendable (URL, any EventSigner, String) -> any PairingChannel = {
            PairingConnection(url: $0, signer: $1, ephemeralPublicKey: $2)
        },
        stepTimeout: Duration = .seconds(30),
        sessionTimeout: Duration = .seconds(120),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) throws {
        let key = try targetKey ?? PrivateKey()
        self.uri = uri
        self.handler = handler
        self.makeConnection = makeConnection
        self.stepTimeout = stepTimeout
        self.sessionTimeout = sessionTimeout
        self.sleep = sleep

        targetPrivateKey = key
        targetPublicKey = key.publicKey
        ephemeralSigner = InMemorySigner(key)
        sourcePublicKey = uri.sourcePublicKey
        sessionSecret = uri.sessionSecret

        let derivedSessionID = PairingCrypto.sessionID(sessionSecret: uri.sessionSecret)
        let ecdh = try PairingCrypto.ecdhShared(targetPrivateKey: key, sourcePublicKey: uri.sourcePublicKey)
        let derivedSasInput = PairingCrypto.sasInput(ecdhShared: ecdh, sessionSecret: uri.sessionSecret)
        sessionID = derivedSessionID
        sasInputBytes = derivedSasInput
        sasCode = PairingCrypto.sasCode(sasInput: derivedSasInput)
        expectedTranscriptHash = PairingCrypto.transcriptHash(
            sessionID: derivedSessionID,
            sourcePublicKey: uri.sourcePublicKey.rawRepresentation,
            targetPublicKey: key.publicKey.rawRepresentation,
            sasInput: derivedSasInput,
            sessionSecret: uri.sessionSecret
        )
        conversationKey = try NIP44.conversationKey(privateKey: key, peer: uri.sourcePublicKey)
    }

    // MARK: - Observation

    /// A live feed of phase, seeded with the current value so a new observer never
    /// misses the phase it subscribed in.
    public func phases() -> AsyncStream<TargetPairingPhase> {
        let (stream, continuation) = AsyncStream.makeStream(of: TargetPairingPhase.self)
        let id = nextObserverID
        nextObserverID += 1
        phaseObservers[id] = continuation
        continuation.yield(phase)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(id) }
        }
        return stream
    }

    private func removeObserver(_ id: Int) {
        phaseObservers.removeValue(forKey: id)
    }

    func setPhase(_ newPhase: TargetPairingPhase) {
        phase = newPhase
    }

    // MARK: - Lifecycle

    /// Begins the session: arms the deadlines, opens the channel, and publishes the
    /// offer. Idempotent — a second call while running is a no-op.
    public func start() async {
        guard internalState == .idle else { return }
        internalState = .connecting
        setPhase(.connecting)
        armSessionDeadline()
        armStepDeadline()

        guard let signer = ephemeralSigner else { return }
        let connection = makeConnection(uri.relays[0], signer, targetPublicKey.hex)
        self.connection = connection
        inboundTask = Task { [weak self] in
            guard let stream = await self?.connection?.inboundEvents() else { return }
            for await event in stream {
                await self?.handleInbound(event)
            }
        }

        do {
            try await connection.open()
        } catch {
            guard !internalState.isTerminal else { return }
            await fail(mapConnectionError(error))
            return
        }
        guard !internalState.isTerminal else { return }
        await publishOffer()
    }

    /// The user confirmed the SAS matches. Records consent and, if the transcript
    /// and payload are already in hand, completes the transfer.
    public func confirmSAS() async {
        guard !internalState.isTerminal else { return }
        userConfirmed = true
        await advanceIfDualConsent()
    }

    /// The user cancelled or denied the SAS. Sends `abort(user_denied)` and
    /// terminates — SAS denial is the primary MITM defence, so the protocol must
    /// not continue.
    public func cancel() async {
        guard !internalState.isTerminal else { return }
        await sendAbort(.userDenied)
        await terminate(.cancelled)
    }

    // MARK: - Deadlines

    func armStepDeadline() {
        stepDeadlineTask?.cancel()
        stepDeadlineTask = Task { [weak self] in
            guard let self else { return }
            // A cancelled sleep (a re-armed or torn-down deadline) must NOT fire —
            // return on any throw rather than swallowing it and calling through.
            do { try await sleep(stepTimeout) } catch { return }
            await self.deadlineFired()
        }
    }

    func cancelStepDeadline() {
        stepDeadlineTask?.cancel()
        stepDeadlineTask = nil
    }

    private func armSessionDeadline() {
        sessionDeadlineTask?.cancel()
        sessionDeadlineTask = Task { [weak self] in
            guard let self else { return }
            do { try await sleep(sessionTimeout) } catch { return }
            await self.deadlineFired()
        }
    }

    private func deadlineFired() async {
        guard !internalState.isTerminal else { return }
        await sendAbort(.timeout)
        await fail(.timedOut)
    }

    // MARK: - Terminal handling

    /// Sends `abort(reason)` best-effort. Must run before ``terminate(_:)`` wipes
    /// the crypto material the abort event needs.
    func sendAbort(_ reason: PairingAbortReason) async {
        guard let event = try? await encryptAndSign(.abort(reason: reason.rawValue)) else { return }
        await publishBestEffort(event)
    }

    /// Publishes an advisory event (abort/complete) bounded by a short deadline, so
    /// a relay that never returns an `OK` cannot wedge the terminal path. The
    /// follow-on ``terminate(_:)`` closes the socket, resolving any publish still in
    /// flight.
    func publishBestEffort(_ event: NostrEvent) async {
        guard let connection else { return }
        let sleep = self.sleep
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await connection.publish(event) }
            group.addTask { try? await sleep(.seconds(5)) }
            _ = await group.next()
            group.cancelAll()
        }
    }

    func fail(_ error: NostrPairError) async {
        await terminate(.failed(error))
    }

    /// The single terminal path: stop the inbound pump and deadlines, close the
    /// socket, wipe all secret material, and publish the terminal phase.
    func terminate(_ terminalPhase: TargetPairingPhase) async {
        guard !internalState.isTerminal else { return }
        internalState = .terminal
        cancelStepDeadline()
        sessionDeadlineTask?.cancel(); sessionDeadlineTask = nil
        inboundTask?.cancel(); inboundTask = nil
        let connection = self.connection
        self.connection = nil
        await connection?.close()
        wipe()
        setPhase(terminalPhase)
    }

    /// Best-effort zeroing of secret buffers and dropping of key references. Swift
    /// value types cannot be reliably overwritten, but zeroing the `Data` buffers
    /// and releasing the key/signer/connection is the most the platform allows —
    /// and closes the Flutter gap of never clearing them at all.
    private func wipe() {
        zero(&sessionSecret)
        zero(&conversationKey)
        zero(&sasInputBytes)
        zero(&expectedTranscriptHash)
        bufferedPayloadCiphertext = nil
        targetPrivateKey = nil
        ephemeralSigner = nil
    }

    private func zero(_ data: inout Data) {
        guard !data.isEmpty else { return }
        data.resetBytes(in: data.startIndex ..< data.endIndex)
    }

    // MARK: - Crypto helpers (see TargetPairingSession+Inbound for the flow)

    /// Encrypts a pairing message to the source and signs it under the ephemeral
    /// key, `p`-tagged to the source.
    func encryptAndSign(_ message: PairingMessage) async throws -> NostrEvent {
        guard let signer = ephemeralSigner else {
            throw NostrPairError.internalError("session wiped")
        }
        let plaintext = try message.jsonString()
        let ciphertext = try NIP44.encrypt(plaintext, conversationKey: conversationKey)
        return try await signer.sign(
            kind: .devicePairing,
            content: ciphertext,
            tags: [["p", sourcePublicKey.hex]]
        )
    }

    /// Decrypts an inbound event's content to a pairing message. NIP-44 rejects any
    /// non-v2 version byte before this returns.
    func decryptMessage(_ ciphertext: String) throws -> PairingMessage {
        let plaintext = try NIP44.decrypt(ciphertext, conversationKey: conversationKey)
        return try PairingMessage.decode(json: plaintext)
    }

    func expectedTranscript() -> Data { expectedTranscriptHash }

    func matchesSourcePeer(_ event: NostrEvent) -> Bool {
        event.pubkey == sourcePublicKey.hex
    }

    func isAddressedToUs(_ event: NostrEvent) -> Bool {
        event.referencedPubkeys.contains(targetPublicKey.hex)
    }
}
