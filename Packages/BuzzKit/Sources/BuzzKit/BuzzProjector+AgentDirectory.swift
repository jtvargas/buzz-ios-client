import Foundation
import GRDB
import NostrCore

extension BuzzProjector {
    /// Projects kinds kept outside the core projector switch so adding an
    /// independent projection does not make that routing choke point grow without
    /// bound.
    static func projectAdditional(_ event: NostrEvent, into db: Database) throws {
        switch event.kind {
        case .agentProfile:
            try projectAgentProfile(event, into: db)
        case .huddleStarted, .huddleEnded:
            try projectHuddle(event, into: db)
        default:
            return
        }
    }

    /// Kind 10100: the persisted Buzz agent directory. It is replaceable per
    /// agent pubkey, so an old reconnect delivery cannot regress eligibility.
    private static func projectAgentProfile(_ event: NostrEvent, into db: Database) throws {
        guard let metadata = try? JSONDecoder().decode(
            AgentDirectoryMetadata.self,
            from: Data(event.content.utf8)
        ) else { return }
        let encoder = JSONEncoder()
        guard let allowlist = String(
            data: try encoder.encode(metadata.respondToAllowlist ?? []),
            encoding: .utf8
        ), let channelIDs = String(
            data: try encoder.encode(metadata.channelIDs ?? []),
            encoding: .utf8
        ) else { return }

        try db.execute(
            sql: """
            INSERT INTO agent_directory (
                pubkey, display_name, respond_to, respond_to_allowlist,
                channel_ids, source_event_id, created_at
            )
            VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(pubkey) DO UPDATE SET
                display_name = excluded.display_name,
                respond_to = excluded.respond_to,
                respond_to_allowlist = excluded.respond_to_allowlist,
                channel_ids = excluded.channel_ids,
                source_event_id = excluded.source_event_id,
                created_at = excluded.created_at
            WHERE excluded.created_at > agent_directory.created_at
               OR (excluded.created_at = agent_directory.created_at
                   AND excluded.source_event_id > agent_directory.source_event_id)
            """,
            arguments: [
                event.pubkey.lowercased(),
                nonempty(metadata.displayName) ?? nonempty(metadata.name),
                metadata.respondTo,
                allowlist,
                channelIDs,
                event.id,
                event.createdAt,
            ]
        )
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct AgentDirectoryMetadata: Decodable {
    let name: String?
    let displayName: String?
    let respondTo: String?
    let respondToAllowlist: [String]?
    let channelIDs: [String]?

    enum CodingKeys: String, CodingKey {
        case name
        case displayName = "display_name"
        case respondTo = "respond_to"
        case respondToAllowlist = "respond_to_allowlist"
        case channelIDs = "channel_ids"
    }
}
