import Foundation
import NostrCore
import OSLog

/// Installation revocation: the gateway keys installations by device token, so
/// one left live blocks every later install from this device with a bare
/// `409 installation_conflict`. Revoking needs the handle *and* an assertion
/// from the App Attest key that enrolled it — there is no handle-only revoke
/// and no lookup endpoint.
extension EnrollmentDriver {
    private static let log = Logger(subsystem: "HivePushKit", category: "EnrollmentDriver.Revocation")

    /// Shown when a live installation blocks enrollment and this app holds no
    /// credentials that can revoke it. Only the gateway operator (or expiry)
    /// can clear the row.
    static let unrecoverableConflictMessage = """
        An earlier push installation for this device is still registered on the gateway \
        and this app no longer has the key to revoke it. Ask the gateway operator to revoke \
        it, or wait for it to expire.
        """

    /// Revokes the enrollment: revokes on the gateway, deletes the lease,
    /// removes the stored enrollment.
    ///
    /// The credentials are moved into the pending-revocation set *before* the
    /// network call, so a crash or failure anywhere in here leaves them on
    /// disk for the 409 path to finish with. The enrollment itself is only
    /// dropped once its credentials are either persisted as pending or no
    /// longer needed because the gateway confirmed the revocation.
    public func revoke() async {
        guard let enrollment = enrollmentStore.load(communityID: communityID) else { return }

        let pendingPersisted: Bool
        do {
            try enrollmentStore.demoteToPendingRevocation(communityID: communityID, gatewayURL: gateway.baseURL)
            pendingPersisted = true
        } catch {
            pendingPersisted = false
            Self.log.error("Could not persist pending revocation; keeping the enrollment: \(String(describing: error))")
        }

        // Revoke the installation on the gateway so re-enrollment won't hit a
        // 409. The gateway keys installations by device token, so a live one
        // blocks every future install from this device until it is revoked or
        // expires (30 days). Revocation needs the handle *and* the App Attest
        // key that enrolled it; when it fails, the pending record keeps both.
        do {
            try await revokeOnGateway(
                handle: enrollment.installationHandle,
                attestKeyID: enrollment.attestKeyID
            )
            enrollmentStore.removePendingRevocation(communityID: communityID)
            enrollmentStore.remove(communityID: communityID)
            Self.log.info("Revoked installation on gateway")
        } catch {
            if pendingPersisted {
                Self.log.warning("Gateway revoke failed; kept as pending revocation: \(String(describing: error))")
            } else {
                let reason = String(describing: error)
                Self.log.error("Gateway revoke failed with no pending record; enrollment left in place: \(reason)")
            }
        }

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
        leaseExpiresAt = nil
        leaseFiltersJSON = nil
        state = .idle
        Self.log.info("Removed enrollment for community \(self.communityID)")
    }

    /// Revokes every installation on this driver's gateway that the app still
    /// holds credentials for.
    ///
    /// Returns `true` when at least one record was settled — revoked, or
    /// known to be gone — so a retry is worth making. Returns `false`, with
    /// `state` set, when there is nothing to revoke or every attempt failed.
    ///
    /// A record is dropped only on a gateway confirmation (2xx) or on a 404
    /// after the installation's known expiry. The gateway answers 404
    /// `not_authorized` for a consumed challenge and for a lost assertion
    /// counter race too, so a 404 before expiry keeps the credentials: the
    /// next attempt gets a fresh challenge and assertion.
    func revokePendingInstallations() async -> Bool {
        let pending = enrollmentStore.loadAllPendingRevocations(gatewayURL: gateway.baseURL)
        guard !pending.isEmpty else {
            state = .failed(.install, Self.unrecoverableConflictMessage)
            Self.log.error("Cannot resolve 409: no pending revocation holds credentials for the live installation")
            return false
        }
        var settled = false
        var lastError: (any Error)?
        let now = Date()
        for record in pending {
            let handle = record.installationHandle
            do {
                try await revokeOnGateway(handle: handle, attestKeyID: record.attestKeyID)
                enrollmentStore.removePendingRevocation(communityID: record.communityID)
                settled = true
                Self.log.info("Revoked pending installation \(handle)")
            } catch {
                if case GatewayError.httpStatus(404, _) = error, record.installationExpiresAt < now {
                    enrollmentStore.removePendingRevocation(communityID: record.communityID)
                    settled = true
                    Self.log.info("Pending installation \(handle) expired and gone from the gateway; dropped")
                    continue
                }
                lastError = error
                Self.log.error("Revoke of \(handle) failed; credentials kept: \(String(describing: error))")
            }
        }
        if !settled, let lastError {
            state = .failed(.install, "Failed to revoke existing installation: \(lastError)")
        }
        return settled
    }

    /// Revokes one installation on the gateway: fresh challenge, assertion with
    /// the installation's own App Attest key over the revoke transcript, POST.
    func revokeOnGateway(handle: String, attestKeyID: String) async throws {
        let challenge = try await gateway.challenge(signer: signer)
        let transcript = RevokeInstallationTranscript(
            v: 1,
            audience: NIPPLAudience.revokeInstallation,
            challengeID: challenge.challengeID,
            challenge: challenge.challenge,
            installationHandle: handle,
            endpointEpoch: Self.endpointEpoch,
            newEndpointEpoch: Self.endpointEpoch + 1
        )
        let assertion = try await attestProvider.assert(
            keyID: attestKeyID,
            clientDataHash: AppAttestClientData.revokeInstallationHash(transcript: transcript)
        )
        try await gateway.revokeInstallation(
            GatewayRevokeRequest(
                challengeID: challenge.challengeID,
                challenge: challenge.challenge,
                installationHandle: handle,
                endpointEpoch: Self.endpointEpoch,
                newEndpointEpoch: Self.endpointEpoch + 1,
                assertion: assertion.base64EncodedString()
            ),
            signer: signer
        )
    }
}
