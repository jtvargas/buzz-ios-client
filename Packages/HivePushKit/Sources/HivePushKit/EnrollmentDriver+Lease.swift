import Foundation
import NostrCore
import OSLog

extension EnrollmentDriver {
    func publishLeaseStep(enrollment: Enrollment) async {
        state = .publishingLease

        do {
            let selfPubkey = try await signer.publicKey().hex
            let filters = NIPPLLease.defaultFilters(selfPubkey: selfPubkey)
            guard let executor = PublicKey(hex: relayPubkey), !executorKeyID.isEmpty, !origin.isEmpty else {
                throw LeaseError.invalidExecutor
            }
            let expiration = enrollment.grantExpiresAt
                ?? enrollment.enrolledAt.addingTimeInterval(NIPPLLease.defaultDuration)
            guard expiration > Date() else { throw LeaseError.expiredEnrollment }
            let leaseEvent: NostrEvent
            if let persisted = enrollment.leaseEvent {
                leaseEvent = persisted
            } else {
                leaseEvent = try await NIPPLLease.create(
                    installID: enrollment.installID,
                    destination: .init(
                        origin: origin, keyID: executorKeyID, publicKey: executor,
                        appProfile: appProfile, endpointGrant: enrollment.endpointGrant
                    ),
                    filters: filters,
                    expiration: expiration,
                    signer: signer
                )
                var updated = enrollment
                updated.leaseEvent = leaseEvent
                try enrollmentStore.write(updated)
            }
            // Retry only temporary quota refusals, using the exact signed event.
            for attempt in 0 ... 2 {
                try Task.checkCancellation()
                do {
                    try await publishEvent(leaseEvent)
                    break
                } catch let RelayConnectionError.publishRejected(reason) {
                    guard case .rateLimited = reason,
                          attempt < 2 else { throw RelayConnectionError.publishRejected(reason) }
                    let seconds = reason.retryAfterSeconds ?? 5
                    guard seconds <= 60 else { throw RelayConnectionError.publishRejected(reason) }
                    try await retrySleep(.seconds(max(1, seconds)))
                }
            }

            leaseExpiresAt = expiration
            let filtersData = try? JSONSerialization.data(withJSONObject: filters, options: [.sortedKeys])
            leaseFiltersJSON = filtersData.flatMap { String(data: $0, encoding: .utf8) }

            state = .enrolled
            Self.enrollmentLog.info("Push lease published for community \(self.communityID)")
        } catch {
            state = .failed(.publishLease, String(describing: error))
            Self.enrollmentLog.error("Lease publication failed: \(String(describing: error))")
        }
    }
}
