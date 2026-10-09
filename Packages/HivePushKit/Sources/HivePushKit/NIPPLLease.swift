import Foundation
import NostrCore

/// Builds and manages NIP-PL push lease events (kind 30350).
///
/// A push lease is an addressable event the client publishes to tell a relay which
/// subscriptions to forward through the push gateway. The relay reads the `exec`
/// tags to find the gateway audiences it is authorised to deliver to, and the
/// NIP-44-encrypted content to find the Nostr filter subscriptions to push for.
///
/// # Lease shape
///
/// ```
/// kind: 30350
/// tags:
///   ["d", "<install-id>"]           — random per-device, makes the lease addressable
///   ["expiration", "<unix>"]        — when the relay should stop pushing
///   ["exec", "<audience-url>", "POST"]  — one per gateway audience
///   ["relay", "<relay-url>"]        — the relay this lease targets
/// content: NIP-44 encrypted JSON array of Nostr filter objects
/// ```
public enum NIPPLLease {
    /// The default lease duration: 30 days. Renewed before expiry by the app or
    /// its background task.
    public static let defaultDuration: TimeInterval = 30 * 24 * 60 * 60

    /// Builds and signs a push lease event.
    ///
    /// - Parameters:
    ///   - installID: the random per-device identifier (used as the `d` tag).
    ///   - relayURL: the relay this lease targets.
    ///   - filters: the Nostr filter subscriptions to push for, as JSON-encodable
    ///     dictionaries. Encrypted into the event content with NIP-44.
    ///   - duration: how long the lease is valid. Defaults to 30 days.
    ///   - signer: the identity key that signs the event and encrypts the content.
    /// - Returns: the signed kind-30350 event ready to publish.
    public static func create(
        installID: String,
        relayURL: String,
        filters: [[String: Any]],
        duration: TimeInterval = defaultDuration,
        signer: some EventSigner
    ) async throws -> NostrEvent {
        let expiration = Int(Date().timeIntervalSince1970 + duration)

        // Encode filters to JSON, then NIP-44-encrypt to self.
        let filtersJSON = try JSONSerialization.data(
            withJSONObject: filters,
            options: [.sortedKeys]
        )
        guard let filtersString = String(data: filtersJSON, encoding: .utf8) else {
            throw LeaseError.filterEncodingFailed
        }
        let encryptedContent = try await signer.encryptToSelf(filtersString)

        let tags: [[String]] = [
            ["d", installID],
            ["expiration", String(expiration)],
            ["exec", NIPPLAudience.installations, "POST"],
            ["exec", NIPPLAudience.delegations, "POST"],
            ["relay", relayURL],
        ]

        return try await signer.sign(
            kind: .pushLease,
            content: encryptedContent,
            tags: tags
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
        let tags: [[String]] = [
            ["e", leaseEventID],
            ["a", "\(EventKind.pushLease.rawValue):\(try await signer.publicKey().hex):\(installID)"],
        ]
        return try await signer.sign(
            kind: .deletion,
            content: "revoke push lease",
            tags: tags
        )
    }

    /// The default filter set for a community: all channel messages and DMs
    /// addressed to this pubkey.
    ///
    /// - Parameters:
    ///   - selfPubkey: the user's hex pubkey.
    ///   - relayURL: the relay URL (used to scope filters).
    public static func defaultFilters(selfPubkey: String) -> [[String: Any]] {
        [
            // Channel messages (kind 9) — the relay decides which channels.
            ["kinds": [EventKind.channelMessage.rawValue]],
            // Rich messages (kind 40002).
            ["kinds": [EventKind.richMessage.rawValue]],
            // DM opens and messages addressed to this user.
            ["kinds": [EventKind.giftWrap.rawValue], "#p": [selfPubkey]],
            // Membership changes (added/removed).
            ["kinds": [EventKind.memberAdded.rawValue, EventKind.memberRemoved.rawValue], "#p": [selfPubkey]],
        ]
    }
}

/// Why a lease could not be built.
public enum LeaseError: Error, Equatable, Sendable {
    /// The filter array could not be serialised to JSON.
    case filterEncodingFailed
}
