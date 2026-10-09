import Foundation
import NostrCore

/// Resolves a generic reconnect wake using only locally enrolled communities.
/// One failed community does not discard previews already resolved for another.
public struct PushWakeResolver: Sendable {
    private let client: PushQueryClient
    private let signer: @Sendable (String) -> any EventSigner
    private let now: @Sendable () -> Date

    public init(
        client: PushQueryClient,
        signer: @escaping @Sendable (String) -> any EventSigner = { IdentityKeychain.signer(account: $0) },
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.client = client
        self.signer = signer
        self.now = now
    }

    /// Publishes each improved preview so extension expiry can deliver partial
    /// progress. Cancellation stops further queries; failures preserve fallback.
    public func resolve(
        communities: [PushCommunitySnapshot],
        didResolve: @Sendable (PushNotification) -> Void
    ) async {
        var best: PushNotification?
        for community in communities.sorted(by: { $0.communityID < $1.communityID }) {
            guard !Task.isCancelled else { return }
            do {
                guard let filters = try queryFilters(for: community), !filters.isEmpty else { continue }
                let reader = signer(community.keychainAccount)
                let pubkey = try await reader.publicKey().hex
                let events = try await client.query(community: community, filters: filters, signer: reader)
                guard !Task.isCancelled else { return }
                // A lease can expire during the network request as well.
                guard community.leaseExpiresAt.map({ $0 > now() }) == true,
                      let candidate = PushNotification.build(events: events, community: community, selfPubkey: pubkey)
                else { continue }
                if let best,
                   candidate.target.createdAt < best.target.createdAt ||
                   (candidate.target.createdAt == best.target.createdAt &&
                    candidate.target.eventID >= best.target.eventID) {
                    continue
                }
                best = candidate
                didResolve(candidate)
            } catch {
                // Missing/locked identity, malformed subscriptions and relay errors
                // all leave this wake's original content (or an earlier preview).
                continue
            }
        }
    }

    private func queryFilters(for community: PushCommunitySnapshot) throws -> [Filter]? {
        guard community.version == PushCommunitySnapshot.currentVersion,
              community.leaseActive,
              let expiry = community.leaseExpiresAt, expiry > now(),
              let subscriptions = community.subscriptionFilters
        else { return nil }
        let knownFields: Set<String> = ["ids", "authors", "kinds", "since", "until", "limit", "search"]
        // Filter's decoder ignores unknown fields. Reject those subscriptions
        // instead of silently dropping a selector and broadening the query.
        guard subscriptions.allSatisfy({ subscription in
            subscription.keys.allSatisfy { knownFields.contains($0) || $0.hasPrefix("#") }
        }) else { return nil }
        return try JSONDecoder().decode(
            [Filter].self, from: JSONSerialization.data(withJSONObject: subscriptions)
        )
    }
}
