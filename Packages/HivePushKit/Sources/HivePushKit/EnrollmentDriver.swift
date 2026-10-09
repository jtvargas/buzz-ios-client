import Foundation
import NostrCore
import OSLog

/// Drives the push enrollment flow from challenge through lease publication.
///
/// An explicit, observable state machine so downstream code — the composition root,
/// a settings UI, a debugger — can inspect exactly where enrollment stands. Each
/// state transition is a single `async` step; a failure at any step is recorded and
/// the driver can be retried from where it left off.
///
/// # Lifecycle
///
/// The driver is created by the composition root when a session starts and the
/// community's relay has push capability. It runs its steps in order:
///
/// 1. Request notification permission.
/// 2. Wait for a device token (provided externally by the app delegate).
/// 3. Challenge the gateway.
/// 4. Generate an App Attest key and attest the challenge.
/// 5. Register the device with the gateway.
/// 6. Delegate the installation to the relay.
/// 7. Publish a NIP-PL lease.
///
/// The driver is `Sendable` and its mutable state is isolated to the actor.
public actor EnrollmentDriver {
    // MARK: - State

    /// Where the enrollment stands.
    public enum State: Equatable, Sendable {
        /// Not started.
        case idle
        /// Waiting for the user to grant notification permission.
        case requestingPermission
        /// Permission granted, waiting for a device token from the system.
        case awaitingDeviceToken
        /// Running the gateway enrollment (challenge → attest → install → delegate).
        case enrolling
        /// Publishing the NIP-PL lease to the relay.
        case publishingLease
        /// Enrollment complete — push is active.
        case enrolled
        /// A step failed; carries the step that failed and the error.
        case failed(FailedStep, String)
    }

    /// Which step failed, so retry can resume from the right place.
    public enum FailedStep: Equatable, Sendable {
        case permission
        case deviceToken
        case challenge
        case attest
        case install
        case delegate
        case publishLease
    }

    public private(set) var state: State = .idle

    private let gateway: GatewayClient
    private let attestProvider: any AppAttestProviding
    private let enrollmentStore: EnrollmentStore
    private let signer: any EventSigner
    private let communityID: String
    private let relayURL: String
    private let relayPubkey: String
    /// The app profile identifier sent to the gateway during installation.
    private let appProfile: String
    /// Callback to publish a signed event to the relay. Injected so this actor has
    /// no dependency on the relay connection.
    private let publishEvent: @Sendable (NostrEvent) async throws -> Void

    /// Continuation for the device token, fulfilled by the app delegate.
    private var tokenContinuation: CheckedContinuation<String, any Error>?

    /// Lease metadata captured after successful publication, for snapshot use.
    public private(set) var leaseExpiresAt: Date?
    public private(set) var leaseFiltersJSON: String?

    private static let log = Logger(subsystem: "HivePushKit", category: "EnrollmentDriver")

    public init(
        gateway: GatewayClient,
        attestProvider: any AppAttestProviding,
        enrollmentStore: EnrollmentStore,
        signer: some EventSigner,
        communityID: String,
        relayURL: String,
        relayPubkey: String,
        appProfile: String = PushConstants.appProfile,
        publishEvent: @escaping @Sendable (NostrEvent) async throws -> Void
    ) {
        self.gateway = gateway
        self.attestProvider = attestProvider
        self.enrollmentStore = enrollmentStore
        self.signer = signer
        self.communityID = communityID
        self.relayURL = relayURL
        self.relayPubkey = relayPubkey
        self.appProfile = appProfile
        self.publishEvent = publishEvent
    }

    // MARK: - Public API

    /// Runs the full enrollment flow. Resumes from the last failed step on retry.
    ///
    /// - Parameters:
    ///   - requestPermission: async closure that asks the user for notification
    ///     permission. Returns `true` if granted. Injected so the driver does not
    ///     import UserNotifications.
    ///   - registerForRemoteNotifications: closure that calls
    ///     `UIApplication.shared.registerForRemoteNotifications()`. Injected so the
    ///     driver has no UIKit dependency.
    public func enroll(
        requestPermission: @Sendable () async throws -> Bool,
        registerForRemoteNotifications: @Sendable @MainActor () -> Void
    ) async {
        // Already enrolled or an enrollment is in flight — bail out.
        switch state {
        case .enrolled:
            return
        case .requestingPermission, .awaitingDeviceToken, .enrolling, .publishingLease:
            Self.log.warning("enroll() called while already in progress (state: \(String(describing: self.state)))")
            return
        case .idle, .failed:
            break
        }

        // If we have a stored enrollment, jump straight to lease publication.
        if let existing = enrollmentStore.load(communityID: communityID) {
            await publishLeaseStep(enrollment: existing)
            return
        }

        // Step 1: Permission.
        state = .requestingPermission
        let granted: Bool
        do {
            granted = try await requestPermission()
        } catch {
            state = .failed(.permission, String(describing: error))
            return
        }
        guard granted else {
            state = .failed(.permission, "Notification permission denied")
            Self.log.info("Notification permission denied by user")
            return
        }

        // Step 2: Register for remote notifications and wait for the token.
        state = .awaitingDeviceToken
        await registerForRemoteNotifications()
        let deviceToken: String
        do {
            deviceToken = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    self.tokenContinuation = continuation
                    // If the task was already cancelled before we stored the
                    // continuation, the onCancel handler missed it. Resume now.
                    if Task.isCancelled {
                        self.tokenContinuation?.resume(throwing: CancellationError())
                        self.tokenContinuation = nil
                    }
                }
            } onCancel: { [self] in
                Task { await self.cancelTokenWait() }
            }
        } catch {
            state = .failed(.deviceToken, String(describing: error))
            return
        }

        // Steps 3-6: Gateway enrollment.
        await gatewayEnrollment(deviceToken: deviceToken)
    }

    /// Called by the app delegate when a device token arrives.
    public func didReceiveDeviceToken(_ tokenHex: String) {
        tokenContinuation?.resume(returning: tokenHex)
        tokenContinuation = nil
    }

    /// Called by the app delegate when registration fails.
    public func didFailToRegisterForRemoteNotifications(_ error: any Error) {
        tokenContinuation?.resume(throwing: error)
        tokenContinuation = nil
    }

    /// Resumes the token continuation with a cancellation error so the
    /// continuation is never leaked. Called from the `onCancel` handler.
    private func cancelTokenWait() {
        tokenContinuation?.resume(throwing: CancellationError())
        tokenContinuation = nil
    }

    /// Whether this community has a completed enrollment.
    public nonisolated var isEnrolled: Bool {
        enrollmentStore.load(communityID: communityID) != nil
    }

    /// Revokes the enrollment: deletes the lease, removes the stored enrollment.
    public func revoke() async {
        guard let enrollment = enrollmentStore.load(communityID: communityID) else { return }
        // Best-effort: publish a deletion event if we can.
        // The lease event ID is not stored, so we publish an addressable deletion.
        let pubkey = try? await signer.publicKey().hex
        if let pubkey {
            let aTag = "\(EventKind.pushLease.rawValue):\(pubkey):\(enrollment.installID)"
            let tags: [[String]] = [["a", aTag]]
            if let deletion = try? await signer.sign(
                kind: .deletion,
                content: "revoke push lease",
                tags: tags
            ) {
                try? await publishEvent(deletion)
                Self.log.info("Published push lease revocation")
            }
        }
        enrollmentStore.remove(communityID: communityID)
        leaseExpiresAt = nil
        leaseFiltersJSON = nil
        state = .idle
        Self.log.info("Removed enrollment for community \(self.communityID)")
    }

    // MARK: - Enrollment steps

    private func gatewayEnrollment(deviceToken: String) async {
        state = .enrolling

        // Step 3: Challenge for enrollment.
        Self.log.info("Requesting enrollment challenge from gateway")
        let enrollChallenge: GatewayChallengeResponse
        do {
            enrollChallenge = try await gateway.challenge(signer: signer)
        } catch {
            state = .failed(.challenge, String(describing: error))
            Self.log.error("Challenge failed: \(String(describing: error))")
            return
        }
        Self.log.info("Received enrollment challenge: \(enrollChallenge.challengeID)")

        // Step 4: App Attest key generation + attestation over the enroll transcript.
        let now = Int64(Date().timeIntervalSince1970)
        let installExpiresAt = now + Int64(NIPPLLease.defaultDuration)
        let endpointEpoch: Int64 = 1

        let enrollTranscript = EnrollTranscript(
            v: 1,
            audience: NIPPLAudience.installations,
            challengeID: enrollChallenge.challengeID,
            challenge: enrollChallenge.challenge,
            keyID: "", // placeholder — filled after key generation
            appProfile: appProfile,
            endpoint: deviceToken,
            endpointEpoch: endpointEpoch,
            expiresAt: installExpiresAt
        )

        guard let attestResult = await performAttestation(
            challenge: enrollChallenge,
            transcriptTemplate: enrollTranscript
        ) else { return }

        // Rebuild transcript with the real key ID.
        let finalEnrollTranscript = EnrollTranscript(
            v: 1,
            audience: NIPPLAudience.installations,
            challengeID: enrollChallenge.challengeID,
            challenge: enrollChallenge.challenge,
            keyID: attestResult.keyID,
            appProfile: appProfile,
            endpoint: deviceToken,
            endpointEpoch: endpointEpoch,
            expiresAt: installExpiresAt
        )

        // Steps 5-6: Install and delegate.
        guard let enrollment = await installAndDelegate(
            deviceToken: deviceToken,
            attestKeyID: attestResult.keyID,
            attestation: attestResult.attestation,
            challenge: enrollChallenge,
            enrollTranscript: finalEnrollTranscript,
            endpointEpoch: endpointEpoch,
            installExpiresAt: installExpiresAt
        ) else { return }

        // Step 7: Publish lease.
        await publishLeaseStep(enrollment: enrollment)
    }

    private func performAttestation(
        challenge: GatewayChallengeResponse,
        transcriptTemplate: EnrollTranscript
    ) async -> (keyID: String, attestation: Data)? {
        guard attestProvider.isSupported else {
            state = .failed(.attest, "App Attest is not supported on this device")
            Self.log.warning("App Attest not supported — enrollment requires a physical device")
            return nil
        }
        do {
            let keyID = try await attestProvider.generateKey()
            // Rebuild transcript with the actual key ID for the hash.
            let transcript = EnrollTranscript(
                v: transcriptTemplate.v,
                audience: transcriptTemplate.audience,
                challengeID: transcriptTemplate.challengeID,
                challenge: transcriptTemplate.challenge,
                keyID: keyID,
                appProfile: transcriptTemplate.appProfile,
                endpoint: transcriptTemplate.endpoint,
                endpointEpoch: transcriptTemplate.endpointEpoch,
                expiresAt: transcriptTemplate.expiresAt
            )
            let clientDataHash = AppAttestClientData.enrollHash(transcript: transcript)
            let attestation = try await attestProvider.attest(keyID: keyID, clientDataHash: clientDataHash)
            Self.log.info("App Attest succeeded with key \(keyID)")
            return (keyID, attestation)
        } catch {
            state = .failed(.attest, String(describing: error))
            Self.log.error("App Attest failed: \(String(describing: error))")
            return nil
        }
    }

    private func installAndDelegate(
        deviceToken: String,
        attestKeyID: String,
        attestation: Data,
        challenge: GatewayChallengeResponse,
        enrollTranscript: EnrollTranscript,
        endpointEpoch: Int64,
        installExpiresAt: Int64
    ) async -> Enrollment? {
        // Step 5: Installation.
        let installRequest = GatewayInstallRequest(
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            keyID: attestKeyID,
            attestation: attestation.base64EncodedString(),
            appProfile: appProfile,
            endpoint: deviceToken,
            endpointEpoch: endpointEpoch,
            expiresAt: installExpiresAt
        )
        let installResponse: GatewayInstallResponse
        do {
            installResponse = try await gateway.install(installRequest, signer: signer)
        } catch {
            state = .failed(.install, String(describing: error))
            Self.log.error("Installation failed: \(String(describing: error))")
            return nil
        }
        Self.log.info("Installation succeeded: \(installResponse.installationHandle)")

        // Step 5b: Request a fresh challenge for delegation.
        Self.log.info("Requesting delegation challenge from gateway")
        let delegateChallenge: GatewayChallengeResponse
        do {
            delegateChallenge = try await gateway.challenge(signer: signer)
        } catch {
            state = .failed(.delegate, String(describing: error))
            Self.log.error("Delegation challenge failed: \(String(describing: error))")
            return nil
        }

        // Step 5c: Build the delegation transcript and generate an assertion.
        let delegateNow = Int64(Date().timeIntervalSince1970)
        let generation: Int64 = 1
        let notBefore = delegateNow
        let delegateExpiresAt = delegateNow + Int64(NIPPLLease.defaultDuration)

        let delegateTranscript = DelegateTranscript(
            v: 1,
            audience: NIPPLAudience.delegations,
            challengeID: delegateChallenge.challengeID,
            challenge: delegateChallenge.challenge,
            installationHandle: installResponse.installationHandle,
            endpointEpoch: endpointEpoch,
            generation: generation,
            relayPubkey: relayPubkey,
            notBefore: notBefore,
            expiresAt: delegateExpiresAt
        )
        let delegateClientDataHash = AppAttestClientData.delegateHash(transcript: delegateTranscript)
        let assertionData: Data
        do {
            assertionData = try await attestProvider.assert(
                keyID: attestKeyID,
                clientDataHash: delegateClientDataHash
            )
        } catch {
            state = .failed(.delegate, String(describing: error))
            Self.log.error("Delegation assertion failed: \(String(describing: error))")
            return nil
        }

        // Step 6: Delegation.
        let delegationRequest = GatewayDelegationRequest(
            challengeID: delegateChallenge.challengeID,
            challenge: delegateChallenge.challenge,
            installationHandle: installResponse.installationHandle,
            endpointEpoch: endpointEpoch,
            generation: generation,
            relayPubkey: relayPubkey,
            notBefore: notBefore,
            expiresAt: delegateExpiresAt,
            assertion: assertionData.base64EncodedString()
        )
        let delegationResponse: GatewayDelegationResponse
        do {
            delegationResponse = try await gateway.delegate(delegationRequest, signer: signer)
        } catch {
            state = .failed(.delegate, String(describing: error))
            Self.log.error("Delegation failed: \(String(describing: error))")
            return nil
        }
        Self.log.info("Delegation succeeded with endpoint grant")

        // Persist.
        let installID = UUID().uuidString
        let enrollment = Enrollment(
            communityID: communityID,
            installationHandle: installResponse.installationHandle,
            endpointGrant: delegationResponse.endpointGrant,
            attestKeyID: attestKeyID,
            installID: installID,
            relayURL: relayURL
        )
        do {
            try enrollmentStore.write(enrollment)
        } catch {
            state = .failed(.install, "Failed to persist enrollment: \(error)")
            Self.log.error("Enrollment persistence failed: \(String(describing: error))")
            return nil
        }
        return enrollment
    }

    private func publishLeaseStep(enrollment: Enrollment) async {
        state = .publishingLease

        do {
            let selfPubkey = try await signer.publicKey().hex
            let filters = NIPPLLease.defaultFilters(selfPubkey: selfPubkey)
            let leaseEvent = try await NIPPLLease.create(
                installID: enrollment.installID,
                relayURL: enrollment.relayURL,
                filters: filters,
                signer: signer
            )
            try await publishEvent(leaseEvent)

            // Capture lease metadata so the snapshot can surface it.
            leaseExpiresAt = Date(timeIntervalSinceNow: NIPPLLease.defaultDuration)
            let filtersData = try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys])
            leaseFiltersJSON = filtersData.flatMap { String(data: $0, encoding: .utf8) }

            state = .enrolled
            Self.log.info("Push lease published for community \(self.communityID)")
        } catch {
            state = .failed(.publishLease, String(describing: error))
            Self.log.error("Lease publication failed: \(String(describing: error))")
        }
    }
}
