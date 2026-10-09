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
    public func revoke() async {
        guard let enrollment = enrollmentStore.load(communityID: communityID) else { return }

        // Revoke the installation on the gateway so re-enrollment won't hit a
        // 409. The gateway keys installations by device token, so a live one
        // blocks every future install from this device until it is revoked or
        // expires (30 days). Revocation needs the handle *and* the App Attest
        // key that enrolled it; when it fails, keep both as a pending
        // revocation so the 409 recovery path can finish the job later.
        do {
            try await revokeOnGateway(
                handle: enrollment.installationHandle,
                attestKeyID: enrollment.attestKeyID
            )
            enrollmentStore.removePendingRevocation(communityID: communityID)
            Self.log.info("Revoked installation on gateway")
        } catch {
            enrollmentStore.savePendingRevocation(PendingRevocation(enrollment: enrollment))
            Self.log.warning("Gateway revoke failed; kept as pending revocation: \(String(describing: error))")
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
        enrollmentStore.remove(communityID: communityID)
        leaseExpiresAt = nil
        leaseFiltersJSON = nil
        state = .idle
        Self.log.info("Removed enrollment for community \(self.communityID)")
    }

    /// Revokes every installation this app still holds credentials for.
    ///
    /// Returns `true` when at least one record was settled — revoked, or
    /// reported gone by the gateway — so a retry is worth making. Returns
    /// `false`, with `state` set, when there is nothing to revoke or every
    /// attempt failed outright.
    func revokePendingInstallations() async -> Bool {
        let pending = enrollmentStore.loadAllPendingRevocations()
        guard !pending.isEmpty else {
            state = .failed(.install, Self.unrecoverableConflictMessage)
            Self.log.error("Cannot resolve 409: no pending revocation holds credentials for the live installation")
            return false
        }
        var settled = false
        var lastError: (any Error)?
        for record in pending {
            let handle = record.installationHandle
            do {
                try await revokeOnGateway(handle: handle, attestKeyID: record.attestKeyID)
                enrollmentStore.removePendingRevocation(communityID: record.communityID)
                settled = true
                Self.log.info("Revoked pending installation \(handle)")
            } catch GatewayError.httpStatus(404, let code) {
                // The gateway no longer has this installation (expired or already
                // gone): nothing left to revoke, and it is not what blocked us.
                enrollmentStore.removePendingRevocation(communityID: record.communityID)
                settled = true
                Self.log.info("Pending installation \(handle) already gone (\(code ?? "not_authorized"))")
            } catch {
                lastError = error
                Self.log.error("Revoke of \(handle) failed: \(String(describing: error))")
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
