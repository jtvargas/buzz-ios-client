import NostrCore
import Observation

/// The subset of ``TargetPairingSession`` the pairing UI drives, behind a seam so
/// the view model can be tested against a scripted session with no crypto or socket.
protocol PairingDriving: Sendable {
    func phases() async -> AsyncStream<TargetPairingPhase>
    func start() async
    func confirmSAS() async
    func cancel() async
}

extension TargetPairingSession: PairingDriving {}

/// Bridges a ``TargetPairingSession`` to ``PairingFlowView``: it parses the scanned
/// QR, starts the session, mirrors its phase into a screen the view renders, and
/// forwards the user's confirm/cancel. On a completed transfer it triggers the
/// engine start (``AppEnvironment/completePairing()``), which flips the app to its
/// running state and dismisses onboarding.
@MainActor
@Observable
final class PairingModel {
    /// What ``PairingFlowView`` should present.
    enum Screen: Equatable {
        case scanning
        case connecting
        case comparing(sasCode: String)
        case transferring
        case completed
        case failed(String)
        case cancelled
    }

    private(set) var screen: Screen = .scanning
    /// A message shown on the scanning screen when a scanned/pasted code is not a
    /// valid pairing QR — recoverable without leaving the scanner.
    private(set) var scanError: String?

    private let makeSession: (NostrPairURI) throws -> any PairingDriving
    private let onImported: () async -> Void
    private var session: (any PairingDriving)?
    private var phaseTask: Task<Void, Never>?

    init(
        makeSession: @escaping (NostrPairURI) throws -> any PairingDriving,
        onImported: @escaping () async -> Void
    ) {
        self.makeSession = makeSession
        self.onImported = onImported
    }

    /// Handles a scanned or pasted string. A bad code sets ``scanError`` and stays
    /// on the scanner; a valid one starts the session.
    func submitScan(_ raw: String) {
        scanError = nil
        let uri: NostrPairURI
        do {
            uri = try NostrPairURI(parsing: raw)
        } catch let error as NostrPairError {
            scanError = Self.scanMessage(for: error)
            return
        } catch {
            scanError = "That isn't a valid Buzz pairing code."
            return
        }

        let session: any PairingDriving
        do {
            session = try makeSession(uri)
        } catch {
            scanError = "Couldn't start pairing on this device."
            return
        }

        self.session = session
        screen = .connecting
        phaseTask?.cancel()
        phaseTask = Task { [weak self] in
            guard let stream = await self?.session?.phases() else { return }
            for await phase in stream {
                await self?.apply(phase)
            }
        }
        Task { await session.start() }
    }

    /// The user confirmed the six-digit codes match.
    func confirmSAS() {
        guard let session else { return }
        Task { await session.confirmSAS() }
    }

    /// The user cancelled or denied the SAS.
    func cancel() {
        guard let session else { return }
        Task { await session.cancel() }
    }

    /// Returns to the scanner after a failure to try a fresh QR.
    func scanAgain() {
        phaseTask?.cancel(); phaseTask = nil
        session = nil
        scanError = nil
        screen = .scanning
    }

    private func apply(_ phase: TargetPairingPhase) async {
        switch phase {
        case .idle, .connecting:
            screen = .connecting
        case let .comparing(sasCode):
            screen = .comparing(sasCode: sasCode)
        case .transferring:
            screen = .transferring
        case .completed:
            screen = .completed
            await onImported()
        case .cancelled:
            screen = .cancelled
        case let .failed(error):
            screen = .failed(Self.failureMessage(for: error))
        }
    }

    // MARK: - Copy

    /// A friendly message for a QR that failed to parse (still on the scanner).
    static func scanMessage(for error: NostrPairError) -> String {
        switch error {
        case .unsupportedVersion:
            "This QR code needs a newer version of Hive. Update the app and try again."
        default:
            "That isn't a valid Buzz pairing code."
        }
    }

    /// A friendly message for a session that failed mid-flight.
    static func failureMessage(for error: NostrPairError) -> String {
        switch error {
        case .transcriptMismatch:
            "The codes didn't match. For your security, pairing was stopped."
        case .timedOut:
            // The desktop's session expires two minutes after its QR appears and
            // then ignores an offer in silence — no error, no code, the QR still
            // on screen. Naming that window is the only actionable thing to say:
            // "timed out" describes our clock, not the one that ran out.
            """
            Your desktop didn't answer. Its pairing code stops working about two \
            minutes after it appears — start pairing again there, then scan it straight away.
            """
        case .peerAborted:
            "Your desktop cancelled the pairing."
        case .importFailed:
            "Couldn't save the identity to this device. Try again."
        case .invalidPayload:
            "Your desktop sent something Hive didn't recognise."
        case .authenticationRejected:
            "The relay refused the connection. Check your relay settings."
        case .connectionFailed, .internalError:
            "Couldn't reach the pairing relay. Make sure both devices are online."
        case .unsupportedVersion:
            "This QR code needs a newer version of Hive."
        default:
            "Pairing couldn't be completed. Please try again."
        }
    }
}
