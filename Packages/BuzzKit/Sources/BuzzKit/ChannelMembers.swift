import Foundation
import GRDB

/// One member of a channel roster, joined to that member's profile.
///
/// A query result, not a stored table: like ``TimelineRow`` and ``ReactionGroup``
/// it is assembled on read by joining the relay-signed `channel_member` roster
/// (kind 39002) to the `profile` projection (kind 0). Reading it fresh — rather
/// than caching a materialized member list — is what lets a single
/// `ValueObservation` over the `channel_member`/`profile` region keep a member
/// list live as the roster changes or a member's profile lands.
///
/// ``displayName`` is the *raw* profile field, left `nil` when no profile row
/// exists yet, so the UI owns the fallback rendering (a truncated key) the same
/// way ``TimelineRow/displayName`` derives it. Keeping the fallback out of this
/// shape means a member with no profile is still returned — present in the roster,
/// merely unnamed — instead of vanishing from the list.
public struct MemberProfile: Sendable, Hashable, Identifiable {
    /// The member's public key. Stable identity for a `ForEach` and the join key
    /// onto ``profile``.
    public let pubkey: String
    /// The member's chosen display name, or `nil` when no profile has been seen or
    /// the profile carries no name. The UI falls back to a short key form, matching
    /// ``TimelineRow/displayName``.
    public let displayName: String?
    /// The member's avatar URL, or `nil` when unknown.
    public let picture: String?
    /// The member's NIP-05 identifier, or `nil` when unknown.
    public let nip05: String?
    /// The member's roster role (e.g. an admin marker), as the roster's `p` tag
    /// carried it, or `nil` when the roster assigned none.
    public let role: String?

    /// Stable across re-reads so a `ForEach` diffs a member in place instead of
    /// tearing the row down when the roster is re-read.
    public var id: String { pubkey }

    public init(
        pubkey: String,
        displayName: String? = nil,
        picture: String? = nil,
        nip05: String? = nil,
        role: String? = nil
    ) {
        self.pubkey = pubkey
        self.displayName = displayName
        self.picture = picture
        self.nip05 = nip05
        self.role = role
    }
}

public extension BuzzEventStore {
    /// The roster of `channel`, each member joined to its profile, in a stable
    /// order for a deterministic list.
    ///
    /// A member with no profile row is still returned — present in the roster,
    /// merely unnamed (all profile fields `nil`) — so the list never drops a member
    /// just because their kind-0 has not arrived. This is the LEFT JOIN's whole
    /// point, and the difference from comb's `members(of:)`, which inner-joined and
    /// so silently hid profileless members.
    ///
    /// Ordering is by display name (case-insensitively, members without a name
    /// sorted last), then by pubkey as a total tiebreak, so the list is the same on
    /// every read regardless of the `channel_member` rows' physical order.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation` can track the `channel_member` and `profile`
    /// tables it reads — the discipline that lets the member list update live, the
    /// same one ``reactions(for:selfPubkey:)`` and ``timeline(channel:before:limit:)``
    /// follow.
    nonisolated func channelMembers(_ channel: String) throws -> [MemberProfile] {
        try reader.read { db in
            try Self.fetchChannelMembers(db, channel: channel)
        }
    }
}

extension BuzzEventStore {
    /// The roster-to-profile join, over an open database so an observation can
    /// track it.
    ///
    /// A `CASE` sorts nameless members after named ones (SQLite orders `NULL`
    /// first by default, which would otherwise float unnamed members to the top);
    /// `COLLATE NOCASE` orders names the way a reader expects; the trailing
    /// `cm.pubkey` breaks a same-name (or all-nameless) tie into a total order.
    static func fetchChannelMembers(_ db: Database, channel: String) throws -> [MemberProfile] {
        let sql = """
        SELECT cm.pubkey      AS pubkey,
               cm.role        AS role,
               p.display_name AS display_name,
               p.picture      AS picture,
               p.nip05        AS nip05
        FROM channel_member cm
        LEFT JOIN profile p ON p.pubkey = cm.pubkey
        WHERE cm.channel_id = ?
        ORDER BY CASE WHEN p.display_name IS NULL OR p.display_name = '' THEN 1 ELSE 0 END ASC,
                 p.display_name COLLATE NOCASE ASC,
                 cm.pubkey ASC
        """
        let rows = try Row.fetchAll(db, sql: sql, arguments: [channel])
        return rows.map { row in
            MemberProfile(
                pubkey: row["pubkey"],
                displayName: row["display_name"],
                picture: row["picture"],
                nip05: row["nip05"],
                role: row["role"]
            )
        }
    }
}
