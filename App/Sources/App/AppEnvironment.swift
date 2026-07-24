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

    /// The store, opened at launch regardless of identity so a returning user's
    /// history is on screen the instant the engine reconnects.
    let store: BuzzEventStore
    let signer: KeychainSigner

    /// Built once an identity and relay URL are known; `nil` until then.
    private(set) var engine: SyncEngine?

    private var engineStateTask: Task<Void, Never>?

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

    /// Forwards a scene-phase change to the engine, if one exists. A no-op before
    /// the engine is built (i.e. while the gate is up).
    func handleScenePhase(_ phase: ScenePhase) {
        guard let engine else { return }
        Task { await forwardScenePhase(phase, to: engine) }
    }

    // MARK: - Engine composition

    private func startEngine(relayURLString: String) async throws {
        guard let websocketURL = RelayEndpoint.websocketURL(from: relayURLString),
              let queryURL = RelayEndpoint.queryURL(for: websocketURL)
        else {
            throw CompositionError.invalidRelayURL
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

        observeEngineState(of: engine)
        try await engine.start()
        phase = .running
    }

    private func observeEngineState(of engine: SyncEngine) {
        engineStateTask?.cancel()
        engineStateTask = Task { [weak self] in
            let states = await engine.states()
            for await state in states {
                self?.engineState = state
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
