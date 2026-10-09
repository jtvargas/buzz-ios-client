import Foundation
import NostrCore

/// The message-query portion of a push wake. The caller must obtain these filters
/// from an active local lease; a community snapshot alone is not push consent.
/// Uses the relay HTTP root in the existing snapshot, never a URL from APNs.
public struct PushQueryClient: Sendable {
    public static let messageKinds: [EventKind] = [9, 40002, 45001, 45003]
    public static let queryLimit = 10

    private let transport: any HTTPTransport

    public init(transport: any HTTPTransport) {
        self.transport = transport
    }

    /// Queries the subscribed message kinds without broadening any subscription.
    /// Empty or unsupported subscriptions do not issue a request. Each filter has
    /// a ten-event ceiling, matching the relay's NIP-01 per-filter limit semantics.
    public func query(
        community: PushCommunitySnapshot,
        filters: [Filter],
        signer: some EventSigner
    ) async throws -> [NostrEvent] {
        try Task.checkCancellation()
        let queries = filters.compactMap { filter -> Filter? in
            var query = filter
            query.kinds = Self.messageKinds.filter { filter.kinds?.contains($0) ?? true }
            guard query.kinds?.isEmpty == false else { return nil }
            query.limit = min(max(filter.limit ?? Self.queryLimit, 0), Self.queryLimit)
            guard query.limit != 0 else { return nil }
            return query
        }
        guard !queries.isEmpty else { return [] }

        let url = community.gatewayURL.appendingPathComponent("query")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode(queries)
        let authorization = try await NIP98.authorizationHeader(
            url: url, method: "POST", body: body, signer: signer
        )
        try Task.checkCancellation()
        let response: (body: Data, status: Int) = try await transport.post(
            body: body,
            to: url,
            headers: ["Content-Type": "application/json", "Authorization": authorization]
        )
        try Task.checkCancellation()
        guard (200 ... 299).contains(response.status) else {
            throw PushQueryError.httpStatus(response.status)
        }
        guard let events = try? JSONDecoder().decode([NostrEvent].self, from: response.body) else {
            throw PushQueryError.unreadableResponse
        }

        return events
    }
}

/// A failed query leaves the original reconnect notification available to the caller.
public enum PushQueryError: Error, Equatable, Sendable {
    case httpStatus(Int)
    case unreadableResponse
}
