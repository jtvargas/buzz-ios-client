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

/// A ``PairedKeyStoring`` double that records stored keys and can be armed to fail,
/// so the importer's success and storage-failure paths are testable off-Keychain.
final class RecordingKeyStore: PairedKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: [PrivateKey] = []
    private let shouldFail: Bool

    init(shouldFail: Bool = false) { self.shouldFail = shouldFail }

    var stored: [PrivateKey] {
        lock.withLock { _stored }
    }

    func store(_ key: PrivateKey) throws {
        if shouldFail { throw StoreError.failed }
        lock.withLock { _stored.append(key) }
    }

    enum StoreError: Error { case failed }
}
