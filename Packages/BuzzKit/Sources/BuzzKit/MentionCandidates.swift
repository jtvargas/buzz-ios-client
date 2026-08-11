import Foundation
import GRDB

/// One identity available to the composer mention autocomplete.
public struct MentionCandidateProfile: Sendable, Hashable, Identifiable {
    public let pubkey: String
    public let displayName: String
    public let picture: String?
    public let secondaryLabel: String?
    public let isAgent: Bool
    public let isChannelMember: Bool

    public var id: String { pubkey }

    public init(
        pubkey: String,
        displayName: String,
        picture: String? = nil,
        secondaryLabel: String? = nil,
        isAgent: Bool,
        isChannelMember: Bool
    ) {
        self.pubkey = pubkey
        self.displayName = displayName
        self.picture = picture
        self.secondaryLabel = secondaryLabel
        self.isAgent = isAgent
        self.isChannelMember = isChannelMember
    }
}

public extension BuzzEventStore {
    /// Channel members plus non-member relay agents the current identity may
    /// invoke, following Buzz Desktop/mobile eligibility:
    ///
    /// - channel members are always candidates;
    /// - `allowlist` agents are candidates when the current user is listed;
    /// - `anyone` agents are candidates when they share an active channel.
    nonisolated func mentionCandidates(
        channel: String,
        selfPubkey: String?
    ) throws -> [MentionCandidateProfile] {
        try reader.read { db in
            try Self.fetchMentionCandidates(db, channel: channel, selfPubkey: selfPubkey)
        }
    }
}

extension BuzzEventStore {
    static func fetchMentionCandidates(
        _ db: Database,
        channel: String,
        selfPubkey: String?
    ) throws -> [MentionCandidateProfile] {
        var candidates = try memberCandidates(db, channel: channel)
        var seen = Set(candidates.map { $0.pubkey.lowercased() })
        try appendEligibleAgents(
            db,
            selfPubkey: selfPubkey,
            seen: &seen,
            candidates: &candidates
        )
        return candidates
    }

    private static func memberCandidates(
        _ db: Database,
        channel: String
    ) throws -> [MentionCandidateProfile] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT cm.pubkey,
               cm.role,
               p.display_name,
               p.picture,
               p.nip05,
               p.oa_owner_pubkey IS NOT NULL AS is_attested_agent
        FROM channel_member cm
        LEFT JOIN profile p ON p.pubkey = cm.pubkey
        WHERE cm.channel_id = ?
        ORDER BY CASE WHEN p.display_name IS NULL OR p.display_name = '' THEN 1 ELSE 0 END,
                 p.display_name COLLATE NOCASE,
                 cm.pubkey
        """, arguments: [channel])

        return rows.map { row in
            let pubkey: String = row["pubkey"]
            let displayName: String? = row["display_name"]
            let role: String? = row["role"]
            let isAttested: Bool = row["is_attested_agent"]
            return MentionCandidateProfile(
                pubkey: pubkey,
                displayName: resolvedName(displayName, pubkey: pubkey),
                picture: row["picture"],
                secondaryLabel: row["nip05"],
                isAgent: role?.lowercased() == "bot" || isAttested,
                isChannelMember: true
            )
        }
    }

    private static func appendEligibleAgents(
        _ db: Database,
        selfPubkey: String?,
        seen: inout Set<String>,
        candidates: inout [MentionCandidateProfile]
    ) throws {
        let sharedChannels = Set(try String.fetchAll(db, sql: "SELECT id FROM channel"))
        // `agent_directory` decides *eligibility* here — `respond_to` and `channel_ids` are
        // the kind-10100's real payload and are the agent's own business to declare. What it
        // must not decide is *agent-ness*: this list offers non-members, so without the
        // attestation join any user could publish a 10100 saying `respond_to: "anyone"` over
        // a channel we share and appear in the composer as an agent. The join is inner by
        // intent — no verified owner attestation, no entry.
        let directoryRows = try Row.fetchAll(db, sql: """
        SELECT ad.pubkey,
               ad.display_name AS directory_name,
               ad.respond_to,
               ad.respond_to_allowlist,
               ad.channel_ids,
               p.display_name,
               p.picture,
               p.nip05
        FROM agent_directory ad
        JOIN profile p ON p.pubkey = ad.pubkey AND p.oa_owner_pubkey IS NOT NULL
        ORDER BY COALESCE(NULLIF(p.display_name, ''), ad.display_name) COLLATE NOCASE,
                 ad.pubkey
        """)

        for row in directoryRows {
            let pubkey: String = row["pubkey"]
            guard !seen.contains(pubkey.lowercased()) else { continue }
            let mode: String? = row["respond_to"]
            let allowlist = decodedStrings(row["respond_to_allowlist"], lowercased: true)
            let channelIDs = decodedStrings(row["channel_ids"], lowercased: false)
            let current = selfPubkey?.lowercased()
            let eligible = (mode == "allowlist" && current.map(allowlist.contains) == true)
                || (mode == "anyone" && !sharedChannels.isDisjoint(with: channelIDs))
            guard eligible else { continue }

            seen.insert(pubkey.lowercased())
            let profileName: String? = row["display_name"]
            let directoryName: String? = row["directory_name"]
            candidates.append(MentionCandidateProfile(
                pubkey: pubkey,
                displayName: resolvedName(
                    nonempty(profileName) ?? directoryName,
                    pubkey: pubkey
                ),
                picture: row["picture"],
                secondaryLabel: row["nip05"],
                isAgent: true,
                isChannelMember: false
            ))
        }
    }

    private static func decodedStrings(_ json: String, lowercased: Bool) -> Set<String> {
        guard let data = json.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return Set(lowercased ? values.map { $0.lowercased() } : values)
    }

    private static func resolvedName(_ displayName: String?, pubkey: String) -> String {
        if let displayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        return String(pubkey.prefix(8))
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
