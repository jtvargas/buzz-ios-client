import Foundation
import HivePushKit
import NostrCore
import OSLog
import Observation
import UIKit
import UserNotifications

/// Coordinates push enrollment for the active community.
///
/// Created by ``AppEnvironment`` when a session starts, torn down with the session.
/// Owns the ``EnrollmentDriver`` and is the single place where:
/// - The relay's NIP-11 push capability is checked.
/// - Notification permission is requested (if needed).
/// - The enrollment flow is kicked off.
///
/// Deliberately separate from ``AppEnvironment`` so push logic can evolve
/// without touching the composition root. The settings UI will call methods on
/// this type to manage leases.
@Observable
@MainActor
final class PushEnrollmentCoordinator {
    /// Whether push enrollment is running or complete for this session.
    enum Status: Equatable {
        case idle
        case checking
        case enrolling
        case enrolled
        case unsupported
        case failed(String)
    }

    /// Everything the coordinator needs to start enrollment, bundled so the call
    /// site stays under the parameter-count limit.
    struct Configuration {
        let communityID: String
        let relayURLString: String
        let gatewayURL: URL
        let pushCapability: PushCapability
        let appProfile: String
        let signer: any EventSigner
        let publishEvent: @Sendable (NostrEvent) async throws -> Void
    }

    private(set) var status: Status = .idle
    @ObservationIgnored private(set) var driver: EnrollmentDriver?
    @ObservationIgnored private let enrollmentStore: EnrollmentStore
    @ObservationIgnored private let pushRegistrar: PushRegistrar

    @ObservationIgnored private var enrollmentTask: Task<Void, Never>?

    /// Called when a lease is published or revoked, so the caller can update the
    /// push snapshot. Parameters: `(communityID, leaseActive, leaseExpiresAt, leaseFiltersJSON)`.
    @ObservationIgnored var onLeaseUpdated: ((String, Bool, Date?, String?) -> Void)?

    private static let log = Logger(subsystem: "Hive", category: "PushEnrollmentCoordinator")

    init(enrollmentStore: EnrollmentStore, pushRegistrar: PushRegistrar) {
        self.enrollmentStore = enrollmentStore
        self.pushRegistrar = pushRegistrar
    }

    /// Starts the push enrollment flow for a community.
    ///
    /// Called from ``AppEnvironment`` after the engine has been created. Runs
    /// asynchronously — the session does not wait for enrollment.
    func startEnrollment(_ config: Configuration) {
        guard config.pushCapability.supports(appProfile: config.appProfile) else {
            status = .unsupported
            Self.log.info("Relay does not support push for this app profile")
            return
        }

        guard let relayKey = config.pushCapability.currentKey else {
            status = .unsupported
            Self.log.warning("Relay has no current push key")
            return
        }

        // Don't early-return here: even if the enrollment exists on disk, the
        // lease may not have been published (e.g. crash between store write and
        // lease publication). The driver's own fast-path detects the stored
        // enrollment and jumps straight to publishLeaseStep.
        enrollmentTask?.cancel()
        enrollmentTask = nil
        status = .enrolling
        let newDriver = makeDriver(config: config, relayPubkey: relayKey.pubkey)
        driver = newDriver
        pushRegistrar.enrollmentDriver = newDriver
        launchEnrollment(newDriver, communityID: config.communityID)
    }

    /// Revokes the push enrollment for a community.
    func revokeEnrollment(communityID: String) async {
        await driver?.revoke()
        driver = nil
        pushRegistrar.enrollmentDriver = nil
        status = .idle
        onLeaseUpdated?(communityID, false, nil, nil)
    }

    /// Tears down the coordinator. Called when a session ends.
    func teardown() {
        enrollmentTask?.cancel()
        enrollmentTask = nil
        pushRegistrar.enrollmentDriver = nil
        driver = nil
        status = .idle
    }

    // MARK: - Private

    private func makeDriver(
        config: Configuration,
        relayPubkey: String
    ) -> EnrollmentDriver {
        let gateway = GatewayClient(
            baseURL: config.gatewayURL,
            transport: URLSessionHTTPTransport()
        )

        #if canImport(DeviceCheck)
        let attestProvider: any AppAttestProviding = DeviceAppAttestProvider()
        #else
        let attestProvider: any AppAttestProviding = UnsupportedAttestProvider()
        #endif

        return EnrollmentDriver(
            gateway: gateway,
            attestProvider: attestProvider,
            enrollmentStore: enrollmentStore,
            signer: config.signer,
            communityID: config.communityID,
            relayURL: config.relayURLString,
            relayPubkey: relayPubkey,
            appProfile: config.appProfile,
            publishEvent: config.publishEvent
        )
    }

    private func launchEnrollment(_ newDriver: EnrollmentDriver, communityID: String) {
        enrollmentTask = Task { [weak self] in
            await newDriver.enroll(
                requestPermission: {
                    try await requestNotificationPermission()
                },
                registerForRemoteNotifications: {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            )
            let finalState = await newDriver.state
            let leaseExpiresAt = await newDriver.leaseExpiresAt
            let leaseFiltersJSON = await newDriver.leaseFiltersJSON
            await MainActor.run {
                switch finalState {
                case .enrolled:
                    self?.status = .enrolled
                    self?.onLeaseUpdated?(communityID, true, leaseExpiresAt, leaseFiltersJSON)
                    Self.log.info("Push enrollment complete")
                case let .failed(step, message):
                    self?.status = .failed("\(step): \(message)")
                    Self.log.error("Push enrollment failed at \(String(describing: step)): \(message)")
                default:
                    break
                }
            }
        }
    }
}

// MARK: - Fallback attest provider for non-iOS builds

#if !canImport(DeviceCheck)
/// A stub that always reports unsupported, used only on macOS for tests.
struct UnsupportedAttestProvider: AppAttestProviding {
    var isSupported: Bool { false }

    func generateKey() async throws -> String {
        throw AppAttestUnavailableError()
    }

    func attest(keyID _: String, clientDataHash _: Data) async throws -> Data {
        throw AppAttestUnavailableError()
    }

    func assert(keyID _: String, clientDataHash _: Data) async throws -> Data {
        throw AppAttestUnavailableError()
    }
}

struct AppAttestUnavailableError: Error {}
#endif
