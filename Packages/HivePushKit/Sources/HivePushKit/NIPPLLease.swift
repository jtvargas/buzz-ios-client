import Foundation
import NostrCore

/// Builds NIP-PL leases encrypted to the relay's advertised executor key.
public enum NIPPLLease {
    public static let defaultDuration: TimeInterval = 30 * 24 * 60 * 60

    /// Discovery and gateway authority needed to address a lease.
    public struct Destination: Sendable {
        let origin: String
        let keyID: String
        let publicKey: PublicKey
        let appProfile: String
        let endpointGrant: String

        public init(origin: String, keyID: String, publicKey: PublicKey, appProfile: String, endpointGrant: String) {
            self.origin = origin
            self.keyID = keyID
            self.publicKey = publicKey
            self.appProfile = appProfile
            self.endpointGrant = endpointGrant
        }
    }

    /// The endpoint is the opaque delegation grant, never the APNs device token.
    public static func create(
        installID: String,
        destination: Destination,
        filters: [[String: Any]],
        expiration: Date,
        signer: some EventSigner
    ) async throws -> NostrEvent {
        let body: [String: Any] = [
            "v": 1,
            "origin": destination.origin,
            "app_profile": destination.appProfile,
            "transport": "apns",
            "endpoint": destination.endpointGrant,
            // The enrollment driver obtains a generation-1 delegation grant.
            "generation": 1,
            "active": true,
            "subscriptions": filters.map { ["filter": $0, "class": "default"] as [String: Any] },
        ]
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let plaintext = String(data: data, encoding: .utf8) else { throw LeaseError.encodingFailed }
        let content = try await signer.encrypt(plaintext, to: destination.publicKey)
        return try await signer.sign(
            kind: .pushLease,
            content: content,
            tags: [
                ["d", installID],
                ["expiration", String(Int64(expiration.timeIntervalSince1970))],
                ["exec", destination.keyID],
            ]
        )
    }

    /// Builds a deletion event (kind 5) that revokes a push lease.
    ///
    /// - Parameters:
    ///   - leaseEventID: the id of the lease event to delete.
    ///   - installID: the `d` tag of the lease being revoked.
    ///   - signer: the identity key.
    /// - Returns: the signed kind-5 deletion event.
    public static func revoke(
        leaseEventID: String,
        installID: String,
        signer: some EventSigner
    ) async throws -> NostrEvent {
        let tags: [[String]] = try await [
            ["e", leaseEventID],
            ["a", "\(EventKind.pushLease.rawValue):\(signer.publicKey().hex):\(installID)"],
        ]
        return try await signer.sign(
            kind: .deletion,
            content: "revoke push lease",
            tags: tags
        )
    }

    /// Message mentions addressed to this identity. The relay
    /// requires narrowed filters and does not advertise gift wraps for push.
    public static func defaultFilters(selfPubkey: String) -> [[String: Any]] {
        [[
            "kinds": [EventKind.channelMessage.rawValue, EventKind.richMessage.rawValue],
            "#p": [selfPubkey],
        ]]
    }
}

public enum LeaseError: Error, Equatable, Sendable {
    case encodingFailed
    case invalidExecutor
    case expiredEnrollment
}
