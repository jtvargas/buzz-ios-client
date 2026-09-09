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
        let value = try String(decoding: JSONEncoder().encode(bounded), as: UTF8.self)
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
