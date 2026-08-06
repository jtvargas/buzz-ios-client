import Foundation
import GRDB
import NostrCore

/// One conversation the reader used recently enough to warm before the ordinary sync pass.
///
/// Channels and threads intentionally share one list: each is one place the reader can
/// return to, and a thread carries its channel so recovery can restore both the narrow
/// reply query and the channel-scoped overlays it depends on.
struct RecentConversationDestination: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case channel
        case thread
    }

    static let capacity = 6

    let kind: Kind
    let channelID: String
    let threadRootID: String?

    static func channel(_ channelID: String) -> Self {
        Self(kind: .channel, channelID: channelID, threadRootID: nil)
    }

    static func thread(channelID: String, rootID: String) -> Self {
        Self(kind: .thread, channelID: channelID, threadRootID: rootID)
    }

    var isValid: Bool {
        guard !channelID.isEmpty else { return false }
        switch kind {
        case .channel:
            return threadRootID == nil
        case .thread:
            return !(threadRootID?.isEmpty ?? true)
        }
    }

    /// Moves `destination` to the front, removes its older occurrence, and keeps the list
    /// bounded. Pure so the exact mixed channel/thread MRU rule can be tested without a DB.
    static func recording(
        _ destination: Self,
        in current: [Self]
    ) -> [Self] {
        guard destination.isValid else { return current }
        return Array(([destination] + current.filter { $0 != destination }).prefix(capacity))
    }
}

extension BuzzEventStore {
    private static func recentConversationKey(identity: String) -> String {
        "recent_conversations:\(identity)"
    }

    /// The persisted six-place MRU for one identity in this community database.
    func recentConversationDestinations(identity: String) async throws -> [RecentConversationDestination] {
        guard !identity.isEmpty else { return [] }
        let key = Self.recentConversationKey(identity: identity)
        return try await reader.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key]
            ), let data = value.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([RecentConversationDestination].self, from: data)
            else { return [] }
            return Array(decoded.filter(\.isValid).prefix(RecentConversationDestination.capacity))
        }
    }

    /// Persists the complete bounded list atomically. The identity is part of the key because
    /// a community database may survive sign-out and later be opened by a different key.
    func saveRecentConversationDestinations(
        _ destinations: [RecentConversationDestination],
        identity: String
    ) async throws {
        guard !identity.isEmpty else { return }
        let bounded = Array(destinations.filter(\.isValid).prefix(RecentConversationDestination.capacity))
        let value = String(decoding: try JSONEncoder().encode(bounded), as: UTF8.self)
        let key = Self.recentConversationKey(identity: identity)
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO meta (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [key, value]
            )
        }
    }
}

extension SyncEngine {
    /// Fetches the exact recent thread roots once per fresh socket, before channel head
    /// reconciliation. A repeated directory refresh in the same ready generation is a no-op.
    func recoverRecentThreads(allowedChannels: Set<String>, generation: Int) async {
        guard isCurrent(generation), recentRecoveryGeneration != generation else { return }
        recentRecoveryGeneration = generation

        var seenRoots: Set<String> = []
        var threads = recentConversationDestinations.compactMap { destination -> (String, String)? in
            guard destination.kind == .thread,
                  allowedChannels.contains(destination.channelID),
                  let root = destination.threadRootID,
                  seenRoots.insert(root).inserted
            else { return nil }
            return (destination.channelID, root)
        }

        // The thread still on screen gets the same complete fetch as opening it. The other
        // recent roots are speculative warmups, so their newest replies share one bounded
        // multi-filter request instead of spending up to five full-thread round trips.
        let activeThreadRoot = recentConversationDestinations.first.flatMap { destination -> String? in
            guard destination.kind == .thread,
                  destination.channelID == activeChannel
            else { return nil }
            return destination.threadRootID
        }
        if let activeThreadRoot,
           let index = threads.firstIndex(where: { $0.1 == activeThreadRoot })
        {
            _ = try? await openThread(root: activeThreadRoot)
            threads.remove(at: index)
        }
        guard isCurrent(generation), !threads.isEmpty else { return }

        let limit = config.threadPrefetchReplyLimit
        let filters = threads.map { _, root in
            Filter(kinds: [.channelMessage], limit: limit, tagQueries: ["e": [root]])
        }
        guard let events = try? await subscriptions.query(filters), isCurrent(generation) else { return }
        _ = try? await store.ingest(batch: events, phase: .backfill)
    }
}
