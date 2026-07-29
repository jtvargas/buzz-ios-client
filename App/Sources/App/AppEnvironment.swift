import BuzzKit
import Foundation
import NostrCore
import SwiftUI

/// The composition root: one `@MainActor @Observable` object, created once in
/// ``HiveApp`` as `@State` and injected down with `.environment(_:)`.
///
/// It builds the production object graph the engine's injectable init was made for
/// — `BuzzEventStore`, `KeychainSigner`, `RelayConnection`, `SubscriptionManager`,
/// `PresenceStore`, `WindowClient`, `SyncEngine` — and owns the launch identity
/// gate and the live engine-state pill's source. Nothing here reaches the socket
/// directly; the engine does (the BuzzKit boundary rule).
@MainActor
@Observable
final class AppEnvironment {
    /// What the root view should present.
    enum Phase: Equatable {
        /// The store is open but no identity is stored yet — show the gate.
        case needsIdentity
        /// An identity is loaded and the engine started — show the app.
        case running
        /// Launch failed in a way the user cannot resolve in-app (e.g. the store
        /// could not be opened). Rare; surfaced rather than crashed.
        case failed(String)
    }

    private(set) var phase: Phase
    /// The engine's lifecycle, mirrored for the toolbar pill. Seeded `.stopped`
    /// and updated from ``SyncEngine/states()``.
    private(set) var engineState: SyncEngine.State = .stopped
    /// Whether this session has ever reached ``SyncEngine/State/running``.
    ///
    /// The one fact that separates *connecting* from *reconnecting*, which the engine
    /// state cannot carry on its own — both are ``SyncEngine/State/starting``. Held
    /// here rather than in the surface that draws the word, because a conversation
    /// opened mid-reconnect has itself never seen a live engine and would otherwise
    /// call a dropped connection a cold start. Reset with the engine on sign-out.
    private(set) var hasConnectedBefore = false

    /// The store, opened at launch regardless of identity so a returning user's
    /// history is on screen the instant the engine reconnects.
    let store: BuzzEventStore
    let signer: KeychainSigner

    /// Built once an identity and relay URL are known; `nil` until then.
    private(set) var engine: SyncEngine?

    /// The authenticated identity's hex pubkey, resolved once the engine starts.
    /// Used to exclude our own typing echo and to key our own presence.
    private(set) var selfPubkeyHex: String?

    private var engineStateTask: Task<Void, Never>?
    /// Publishes our own presence: `"online"` every 60 s while foregrounded, and
    /// `"offline"` on background. Built alongside the engine.
    private var heartbeat: PresenceHeartbeat?

    /// Opens the store and prepares the signer. The engine is not built yet — that
    /// waits until an identity is present (a returning user) or entered (the gate).
    init() throws {
        signer = KeychainSigner(account: "primary")
        store = try Self.makeStore()
        phase = .needsIdentity
    }

    /// Resolves launch state: if a key is already stored, start the engine against
    /// the persisted relay URL; otherwise rest on the identity gate.
    func bootstrap() async {
        do {
            if try signer.loadPrivateKey() != nil {
                try await startEngine(relayURLString: RelayEndpoint.storedURLString)
            } else {
                phase = .needsIdentity
            }
        } catch {
            phase = .failed(String(describing: error))
        }
    }

    /// Completes the identity gate: validates the relay URL, decodes the pasted
    /// `nsec` into a key, commits it to the Keychain, and starts the engine. The
    /// secret never leaves the Keychain — the decoded key is handed straight to
    /// `signer.store` and not retained here.
    func submitIdentity(relayURLString: String, nsec: String) async -> IdentityGateError? {
        guard RelayEndpoint.websocketURL(from: relayURLString) != nil else {
            return .invalidRelayURL
        }
        let trimmedSecret = nsec.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: PrivateKey
        do {
            key = try PrivateKey(nsec: trimmedSecret)
        } catch {
            return .invalidSecretKey
        }
        do {
            try signer.store(key)
            RelayEndpoint.storedURLString = relayURLString
            try await startEngine(relayURLString: relayURLString)
            return nil
        } catch {
            return .couldNotStart(String(describing: error))
        }
    }

    /// Creates a brand-new identity in-app: generates a fresh secp256k1 key,
    /// commits it to the Keychain, and starts the engine against the given relay.
    /// The generated key is handed straight to `signer.store` and never retained
    /// here — the same custody discipline as the paste path.
    func createIdentity(relayURLString: String) async -> IdentityGateError? {
        guard RelayEndpoint.websocketURL(from: relayURLString) != nil else {
            return .invalidRelayURL
        }
        let key: PrivateKey
        do {
            key = try PrivateKey()
        } catch {
            return .couldNotStart(String(describing: error))
        }
        do {
            try signer.store(key)
            RelayEndpoint.storedURLString = relayURLString
            try await startEngine(relayURLString: relayURLString)
            return nil
        } catch {
            return .couldNotStart(String(describing: error))
        }
    }

    /// The application-specific sink a ``TargetPairingSession`` hands its decrypted
    /// credential to. It commits the imported key to the Keychain and persists the
    /// paired relay; the session sends `complete(true)` only if it succeeds.
    func pairingImporter() -> PairingCredentialImporter {
        PairingCredentialImporter(keyStore: signer)
    }

    /// Finishes a completed pairing by starting the engine against the relay the
    /// importer just persisted. The key is already durably stored (that is what let
    /// the session acknowledge), so this only brings the connection up.
    func completePairing() async -> IdentityGateError? {
        do {
            try await startEngine(relayURLString: RelayEndpoint.storedURLString)
            return nil
        } catch {
            return .couldNotStart(String(describing: error))
        }
    }

    /// Signs the current identity out: removes the key from the Keychain, stops the
    /// engine, and returns to onboarding.
    ///
    /// The key deletion is verified *before* anything is torn down. If the key could
    /// not be removed (a Keychain failure), the running session is left intact and
    /// ``SignOutResult/keyNotCleared`` is returned — a sign-out never reports success
    /// while the `nsec` is still recoverable on this device. Deleting the key while
    /// the engine is briefly still live is safe: the signer loads fresh per operation,
    /// and the engine is stopped immediately after.
    ///
    /// The store is intentionally **not** wiped here. The recorded store owner is
    /// left in place so the next login decides: a same-key re-login keeps the
    /// history, and a different key logging in wipes it in ``startEngine(relayURLString:)``.
    @discardableResult
    func signOut() async -> SignOutResult {
        guard deleteAndVerifyKey(signer) == .signedOut else {
            return .keyNotCleared // still signed in; nothing torn down
        }
        engineStateTask?.cancel()
        engineStateTask = nil
        if let engine {
            await engine.stop()
        }
        heartbeat = nil
        engine = nil
        selfPubkeyHex = nil
        engineState = .stopped
        hasConnectedBefore = false
        phase = .needsIdentity
        return .signedOut
    }

    /// Loads the stored secret key for a gated backup/reveal, or `nil` if none is
    /// stored. The caller must gate this behind device authentication and never
    /// persist or log the result — it is the one deliberate read-out boundary for
    /// the secret.
    func revealSecretKey() -> PrivateKey? {
        try? signer.loadPrivateKey()
    }

    /// Forwards a scene-phase change to the engine and drives the presence
    /// heartbeat, if an engine exists. A no-op before the engine is built (i.e. while
    /// the gate is up).
    ///
    /// On background the heartbeat publishes `"offline"` *before* the engine arms its
    /// grace window, so the departure goes out while the socket is still live; on
    /// foreground it forwards first, then resumes beating.
    func handleScenePhase(_ phase: ScenePhase) {
        guard let engine else { return }
        let heartbeat = self.heartbeat
        Task {
            switch phase {
            case .active:
                await forwardScenePhase(phase, to: engine)
                heartbeat?.startForeground()
            case .background:
                await heartbeat?.stopBackground()
                await forwardScenePhase(phase, to: engine)
            case .inactive:
                await forwardScenePhase(phase, to: engine)
            @unknown default:
                break
            }
        }
    }

    // MARK: - Engine composition

    private func startEngine(relayURLString: String) async throws {
        guard let websocketURL = RelayEndpoint.websocketURL(from: relayURLString),
              let queryURL = RelayEndpoint.queryURL(for: websocketURL)
        else {
            throw CompositionError.invalidRelayURL
        }

        // Resolve the identity before the engine writes anything, so a store left by
        // a *different* key (a sign-out then a new login) is wiped first; a same-key
        // re-login keeps its history. A fresh install has no recorded owner.
        let intendedPubkey = try? await signer.publicKey().hex
        if let intendedPubkey {
            if StoreOwnership.shouldWipe(forIncoming: intendedPubkey) {
                try await store.wipe()
            }
            StoreOwnership.ownerPubkeyHex = intendedPubkey
        }

        let connection = RelayConnection(url: websocketURL, signer: signer)
        let subscriptions = SubscriptionManager(connection: connection, signer: signer)
        let presence = PresenceStore()
        let windowClient = WindowClient(
            transport: URLSessionHTTPTransport(),
            queryURL: queryURL,
            signer: signer
        )
        let engine = SyncEngine(
            connection: connection,
            subscriptions: subscriptions,
            store: store,
            presence: presence,
            windowClient: windowClient,
            signer: signer
        )
        self.engine = engine
        heartbeat = PresenceHeartbeat(publisher: engine)

        observeEngineState(of: engine)
        try await engine.start()
        // The identity, resolved above, keys presence and excludes our own typing
        // echo; a nil (Keychain read failure) degrades presence to keyless.
        selfPubkeyHex = intendedPubkey
        phase = .running
        // Launch is a foreground start; scene-phase `.onChange` does not fire for the
        // initial value, so begin beating explicitly here.
        heartbeat?.startForeground()
    }

    private func observeEngineState(of engine: SyncEngine) {
        engineStateTask?.cancel()
        engineStateTask = Task { [weak self] in
            let states = await engine.states()
            for await state in states {
                self?.engineState = state
                if state == .running { self?.hasConnectedBefore = true }
            }
        }
    }

    // MARK: - Store location

    private static func makeStore() throws -> BuzzEventStore {
        let directory = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Hive", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("store.sqlite").path
        return try BuzzEventStore(path: path)
    }

    private enum CompositionError: Error {
        case invalidRelayURL
    }
}

/// A reason the identity gate could not proceed, phrased for display.
enum IdentityGateError: Equatable {
    case invalidRelayURL
    case invalidSecretKey
    case couldNotStart(String)

    var message: String {
        switch self {
        case .invalidRelayURL:
            "Enter a valid relay URL, e.g. ws://100.111.202.55:3004"
        case .invalidSecretKey:
            "That doesn't look like a valid nsec key."
        case let .couldNotStart(detail):
            "Couldn't connect: \(detail)"
        }
    }
}
