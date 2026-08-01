import Foundation
@testable import Hive
import NostrCore

/// A scripted ``PairingDriving`` so ``PairingModel`` can be tested without any
/// crypto or socket: the test emits phases and reads back the forwarded actions.
actor FakePairingSession: PairingDriving {
    private var continuation: AsyncStream<TargetPairingPhase>.Continuation?
    private(set) var started = false
    private(set) var confirmed = false
    private(set) var cancelled = false

    func phases() -> AsyncStream<TargetPairingPhase> {
        let (stream, continuation) = AsyncStream.makeStream(of: TargetPairingPhase.self)
        self.continuation = continuation
        return stream
    }

    func start() { started = true }
    func confirmSAS() { confirmed = true }
    func cancel() { cancelled = true }

    /// Pushes a phase to the model's observer.
    func emit(_ phase: TargetPairingPhase) {
        continuation?.yield(phase)
    }
}

/// A ``PairedKeyStoring`` double that records what was stored and against which relay, and
/// can be armed to fail — so the importer's success and storage-failure paths are testable
/// off-Keychain and without a community list.
final class RecordingKeyStore: PairedKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: [(key: PrivateKey, relay: String)] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    var stored: [PrivateKey] {
        lock.withLock { _stored.map(\.key) }
    }

    /// The relays the importer asked for, in order. The relay is half of what the importer
    /// now hands over — a credential names the community it belongs to.
    var storedRelays: [String] {
        lock.withLock { _stored.map(\.relay) }
    }

    func storePairedKey(_ key: PrivateKey, forRelay relayURLString: String) async -> Bool {
        if shouldFail { return false }
        lock.withLock { _stored.append((key, relayURLString)) }
        return true
    }
}
