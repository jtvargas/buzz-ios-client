import BuzzKit
import GRDB

struct AgentMonitoringMetadata: Sendable {
    let names: EntityNames
    static let empty = AgentMonitoringMetadata(names: .empty)

    /// Only during an opted-in session, off the main actor, at most every 15 s.
    /// Read channel labels directly; no unread counts or timeline scans are needed.
    nonisolated static func read(store: BuzzEventStore, selfPubkey: String?) async throws -> Self {
        let directory = try store.directorySnapshot(selfPubkey: selfPubkey)
        let channels = try await store.reader.read { database in
            try Row.fetchAll(database, sql: "SELECT id, name, is_private, channel_type FROM channel").map { row in
                ChannelListRow(
                    id: row["id"], name: row["name"], about: nil, picture: nil,
                    isPrivate: row["is_private"], lastMessageAt: nil,
                    lastMessageSnippet: nil, lastMessageAuthor: nil, channelType: row["channel_type"]
                )
            }
        }
        return Self(names: EntityNames(snapshot: directory, channels: channels, selfPubkey: selfPubkey))
    }
}
