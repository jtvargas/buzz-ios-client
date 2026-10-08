import GRDB

public extension BuzzEventStore {
    /// Other participants to notify on every DM send, even without an explicit `@`.
    /// Unknown and non-DM channels return no automatic recipients.
    nonisolated func directMessageRecipients(channel: String, selfPubkey: String?) throws -> [String] {
        try reader.read { db in
            try String.fetchAll(db, sql: """
            SELECT cm.pubkey
            FROM channel_member cm
            JOIN channel c ON c.id = cm.channel_id
            WHERE cm.channel_id = :channel
              AND c.channel_type = 'dm'
              AND cm.pubkey <> :selfPubkey
            """, arguments: [
                "channel": channel,
                // Keep the indexed column binary; normalize the parameter, not the roster.
                "selfPubkey": selfPubkey?.lowercased() ?? "",
            ])
        }
    }
}
