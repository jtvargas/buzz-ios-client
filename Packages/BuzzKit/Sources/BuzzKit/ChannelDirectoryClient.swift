import Foundation
import NostrCore

public protocol ChannelDirectoryFetching: Sendable {
    func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot
}

/// A concrete boundary around any directory fetcher.
///
/// ``SyncEngine`` accepts this concrete value rather than putting an existential
/// or opaque generic directly in an actor initializer. The underlying fetcher is
/// still injected and retained behind the engine's reference context, while the
/// stable initializer shape avoids Swift's actor-initializer code-generation
/// failure for the legacy no-directory overload.
public struct AnyChannelDirectoryFetcher: ChannelDirectoryFetching, Sendable {
    private let fetchValue: @Sendable (String, Set<String>) async throws -> ChannelDirectorySnapshot

    public init<Fetcher: ChannelDirectoryFetching>(_ fetcher: Fetcher) {
        fetchValue = { selfPubkey, previouslyActiveChannels in
            try await fetcher.fetch(
                selfPubkey: selfPubkey,
                previouslyActiveChannels: previouslyActiveChannels
            )
        }
    }

    public func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        try await fetchValue(selfPubkey, previouslyActiveChannels)
    }
}

public enum ChannelDirectoryError: Error, Equatable {
    case transport(TransportError)
    case httpStatus(Int)
    case unreadableResponse
    case invalidPagination
}

/// Authenticated, composite-cursor traversal of the relay's channel directory.
///
/// Every query is completed before a snapshot is returned. The caller therefore
/// has only two outcomes: a complete value safe to commit atomically, or an error
/// that leaves the prior store state untouched.
public struct ChannelDirectoryClient: ChannelDirectoryFetching, Sendable {
    public static let pageSize = 500
    public static let channelBatchSize = 100

    private let transport: any HTTPTransport
    private let queryURL: URL
    private let signer: any EventSigner

    public init(transport: any HTTPTransport, queryURL: URL, signer: some EventSigner) {
        self.transport = transport
        self.queryURL = queryURL
        self.signer = signer
    }

    public func fetch(
        selfPubkey: String,
        previouslyActiveChannels: Set<String>
    ) async throws -> ChannelDirectorySnapshot {
        try Task.checkCancellation()

        let membershipPages = try await fetchAll(
            DirectoryFilter(
                kinds: [.groupMembers],
                tagQueries: ["p": [selfPubkey]]
            )
        )
        let currentMembership = Self.latestReplaceables(in: membershipPages)
        let currentChannels: Set<String> = Set(
            currentMembership.compactMap { event in
                guard event.kind == EventKind.groupMembers,
                      Self.roster(event, contains: selfPubkey)
                else { return nil }
                return event.addressableIdentifier
            }
        )

        let relevantChannels = currentChannels.union(previouslyActiveChannels)
        var stateEvents: [NostrEvent] = []
        let ordered = relevantChannels.sorted()
        for start in stride(from: 0, to: ordered.count, by: Self.channelBatchSize) {
            try Task.checkCancellation()
            let end = min(start + Self.channelBatchSize, ordered.count)
            stateEvents += try await fetchAll(
                DirectoryFilter(
                    kinds: [.groupMetadata, .groupAdmins, .groupMembers],
                    tagQueries: ["d": Array(ordered[start ..< end])]
                )
            )
        }

        let events = Self.latestReplaceables(in: membershipPages + stateEvents)
        let byChannel = Dictionary(grouping: events) { $0.addressableIdentifier ?? "" }
        var states: [String: ChannelAccessState] = [:]
        for channelID in relevantChannels {
            let channelEvents = byChannel[channelID] ?? []
            let roster: NostrEvent? = channelEvents.first {
                $0.kind == EventKind.groupMembers
            }
            let metadata: NostrEvent? = channelEvents.first {
                $0.kind == EventKind.groupMetadata
            }
            let isMember = roster.map { Self.roster($0, contains: selfPubkey) } ?? false
            let isArchived = metadata.map(Self.isArchived) ?? false

            if isMember {
                states[channelID] = metadata == nil ? .unavailable : (isArchived ? .archived : .active)
            } else if isArchived {
                states[channelID] = .archived
            } else if roster != nil {
                states[channelID] = .notMember
            } else {
                // Absence cannot distinguish deletion from an authorization loss.
                states[channelID] = .unavailable
            }
        }

        return ChannelDirectorySnapshot(events: events, states: states)
    }

    private func fetchAll(_ base: DirectoryFilter) async throws -> [NostrEvent] {
        var cursor: DirectoryCursor?
        var priorCursor: DirectoryCursor?
        var result: [NostrEvent] = []

        while true {
            try Task.checkCancellation()
            var filter = base
            filter.limit = Self.pageSize
            filter.cursor = cursor
            let page = try await fetchPage(filter)
            result += page
            guard page.count == Self.pageSize else { return result }

            let next = try Self.paginationCursor(for: page)
            guard next != priorCursor else {
                throw ChannelDirectoryError.invalidPagination
            }
            priorCursor = next
            cursor = next
        }
    }

    static func paginationCursor(for page: [NostrEvent]) throws -> DirectoryCursor {
        guard let oldest = page.min(by: {
            ($0.createdAt, $0.id) < ($1.createdAt, $1.id)
        }) else {
            throw ChannelDirectoryError.invalidPagination
        }
        return DirectoryCursor(createdAt: oldest.createdAt, id: oldest.id)
    }

    private func fetchPage(_ filter: DirectoryFilter) async throws -> [NostrEvent] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = try encoder.encode([filter])
        let authorization = try await NIP98.authorizationHeader(
            url: queryURL,
            method: "POST",
            body: body,
            signer: signer
        )

        let response: (body: Data, status: Int)
        do {
            response = try await transport.post(
                body: body,
                to: queryURL,
                headers: [
                    "Content-Type": "application/json",
                    "Authorization": authorization,
                ]
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TransportError {
            throw ChannelDirectoryError.transport(error)
        }

        try Task.checkCancellation()
        guard (200 ... 299).contains(response.status) else {
            throw ChannelDirectoryError.httpStatus(response.status)
        }
        guard let events = try? JSONDecoder().decode([NostrEvent].self, from: response.body) else {
            throw ChannelDirectoryError.unreadableResponse
        }
        return events
    }

    /// Collapses addressable group state by `(kind, d)`, choosing the greatest
    /// `(created_at, event_id)` cursor so delivery order cannot affect the result.
    static func latestReplaceables(in events: [NostrEvent]) -> [NostrEvent] {
        var latest: [String: NostrEvent] = [:]
        for event in events {
            guard let identifier = event.addressableIdentifier else { continue }
            let key = "\(event.kind.rawValue):\(identifier)"
            if let existing = latest[key],
               (event.createdAt, event.id) <= (existing.createdAt, existing.id) {
                continue
            }
            latest[key] = event
        }
        return latest.values.sorted {
            ($0.createdAt, $0.id) > ($1.createdAt, $1.id)
        }
    }

    private static func roster(_ event: NostrEvent, contains pubkey: String) -> Bool {
        event.tags.contains { tag in
            guard tag.count > 1, tag[0] == "p" else { return false }
            return tag[1].caseInsensitiveCompare(pubkey) == .orderedSame
        }
    }

    private static func isArchived(_ event: NostrEvent) -> Bool {
        event.tags.contains { tag in
            guard tag.count > 1 else { return false }
            return tag[0].lowercased() == "archived"
                && tag[1].lowercased() == "true"
        }
    }
}

struct DirectoryCursor: Encodable, Equatable {
    let createdAt: Int64
    let id: String
}

struct DirectoryFilter: Encodable {
    var kinds: [EventKind]
    var tagQueries: [String: [String]]
    var limit = ChannelDirectoryClient.pageSize
    var cursor: DirectoryCursor?

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(kinds.map(\.rawValue), forKey: Key("kinds"))
        try container.encode(limit, forKey: Key("limit"))
        for (name, values) in tagQueries {
            try container.encode(values, forKey: Key("#\(name)"))
        }
        if let cursor {
            try container.encode(cursor.createdAt, forKey: Key("until"))
            try container.encode(cursor.id, forKey: Key("before_id"))
        }
    }
}
