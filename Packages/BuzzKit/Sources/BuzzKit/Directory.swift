import Foundation
import GRDB

/// One identity as the UI needs to *name* it: the raw fields a display name falls
/// back through, plus whether the identity is an agent.
///
/// The fields are deliberately raw and optional, the same posture
/// ``MemberProfile`` takes: resolution order is a presentation decision, so the
/// store hands back what it knows and the UI owns the fallback. Unlike
/// ``MentionRef/displayName``, nothing here is pre-resolved to a key prefix.
public struct DirectoryEntity: Sendable, Hashable, Identifiable {
    /// The identity's public key, lowercased — also the snapshot's key.
    public let pubkey: String
    /// The kind-0 profile's display name, or `nil` when no profile has been seen or
    /// it carries none.
    public let profileName: String?
    /// The kind-10100 agent directory's display name, or `nil` for a non-agent (or
    /// an agent whose directory entry carries no name).
    public let agentName: String?
    /// The profile's avatar URL, or `nil` when unknown.
    public let picture: String?
    /// The profile's NIP-05 identifier, or `nil` when unknown.
    public let nip05: String?
    /// Whether this identity is an agent: a roster `bot` role, or presence in the
    /// relay's agent directory — the same test composer autocomplete applies.
    public let isAgent: Bool

    public var id: String { pubkey }

    public init(
        pubkey: String,
        profileName: String? = nil,
        agentName: String? = nil,
        picture: String? = nil,
        nip05: String? = nil,
        isAgent: Bool = false
    ) {
        self.pubkey = pubkey
        self.profileName = profileName
        self.agentName = agentName
        self.picture = picture
        self.nip05 = nip05
        self.isAgent = isAgent
    }
}

/// Every identity the UI may have to name, plus the rosters that tell a direct
/// message from a channel — assembled in one read.
///
/// The normalized lookup shape the UI needs: a view resolves a name, an avatar, or
/// a conversation's peer by dictionary subscript instead of issuing a query (or a
/// roster scan) per row. Like ``ChannelListRow`` this is a query result rather than
/// a stored table, so one `ValueObservation` over `channel_member`, `profile`, and
/// `agent_directory` keeps the whole directory live.
///
/// Scope is deliberate: identities that appear in *some* channel roster or in the
/// agent directory, **plus the reader's own**. A message author who has since left
/// every channel is not here — that row already carries its own resolved
/// ``TimelineRow/authorName`` from the same `profile` projection, so nothing is left
/// unnamed by the omission.
///
/// The reader is in scope unconditionally because they are the one identity every
/// screen draws whether or not a roster mentions them — the account button in the
/// home toolbar is on screen before any conversation is open. Leaving them to the
/// roster rule made that button a `?` on a plain tile for exactly the people it
/// mattered most for: a freshly invited member is on **no** roster in their new
/// community (see ``ChannelDirectoryClient/fetch(selfPubkey:previouslyActiveChannels:)``
/// — every channel they can see there is *open* rather than joined), so their own
/// kind-0 was scoped out of the read that names them while sitting in the `profile`
/// table the account sheet reads directly.
public struct DirectorySnapshot: Sendable, Hashable {
    /// Identities keyed by lowercased pubkey.
    public let entities: [String: DirectoryEntity]
    /// Each channel's member keys, lowercased — the roster shape a DM test needs.
    public let memberPubkeysByChannel: [String: Set<String>]

    public init(
        entities: [String: DirectoryEntity] = [:],
        memberPubkeysByChannel: [String: Set<String>] = [:]
    ) {
        self.entities = entities
        self.memberPubkeysByChannel = memberPubkeysByChannel
    }

    /// The empty directory: what a surface sees before the first snapshot lands.
    public static let empty = DirectorySnapshot()

    /// The identity for `pubkey`, case-insensitively, or `nil` when unknown here.
    public func entity(_ pubkey: String) -> DirectoryEntity? {
        entities[pubkey.lowercased()]
    }

    /// `channel`'s member keys, or an empty set when its roster has not landed.
    public func members(of channel: String) -> Set<String> {
        memberPubkeysByChannel[channel] ?? []
    }
}

public extension BuzzEventStore {
    /// Every nameable identity and every channel roster in one read.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation.tracking` can watch the `channel_member`,
    /// `profile`, and `agent_directory` tables it reads — the discipline that lets
    /// ``channelList(selfPubkey:)`` and ``timeline(channel:before:limit:)`` back
    /// live views.
    ///
    /// - Parameter selfPubkey: the reader, who is in scope whether or not a roster
    ///   names them (§ ``DirectorySnapshot``). `nil` only for a read with no session,
    ///   and then nobody's own face is being drawn either.
    nonisolated func directorySnapshot(selfPubkey: String? = nil) throws -> DirectorySnapshot {
        try reader.read { db in
            try Self.fetchDirectorySnapshot(db, selfPubkey: selfPubkey)
        }
    }
}

extension BuzzEventStore {
    /// The roster + profile + agent-directory assembly, over an open database so an
    /// observation can track it.
    ///
    /// Separate statements rather than one join: the roster read is also the source of
    /// the DM test, and the profile read is scoped rather than whole (§
    /// ``profileRows(_:identity:)``).
    static func fetchDirectorySnapshot(
        _ db: Database,
        selfPubkey: String? = nil
    ) throws -> DirectorySnapshot {
        // Lowercased on the way in, because that is the key every table here is
        // compared on and the spelling ``DirectorySnapshot/entity(_:)`` looks up.
        let identity = selfPubkey?.lowercased()
        var rosters: [String: Set<String>] = [:]
        var botRoles: Set<String> = []
        let memberRows = try Row.fetchAll(
            db,
            sql: "SELECT channel_id, pubkey, role FROM channel_member"
        )
        for row in memberRows {
            let channelID: String = row["channel_id"]
            let pubkey = (row["pubkey"] as String).lowercased()
            rosters[channelID, default: []].insert(pubkey)
            if (row["role"] as String?)?.lowercased() == "bot" {
                botRoles.insert(pubkey)
            }
        }

        var agentNames: [String: String?] = [:]
        let agentRows = try Row.fetchAll(
            db,
            sql: "SELECT pubkey, display_name FROM agent_directory"
        )
        for row in agentRows {
            agentNames[(row["pubkey"] as String).lowercased()] = nonempty(row["display_name"])
        }

        let profiles = try profileRows(db, identity: identity)

        // The pubkeys whose kind-0 carries a NIP-OA owner attestation this device verified
        // at projection time (``BuzzProjector.projectProfile``). This — not the kind-10100
        // directory — is what says "agent", because it is the only one of the two an
        // impostor cannot mint for themselves: the owner's key has to sign it, and
        // self-attestation is refused. `agent_directory` still supplies a *name* below,
        // which is self-asserted in exactly the way a kind-0 `display_name` already is.
        var attestedAgents: Set<String> = []
        for (pubkey, row) in profiles where (row["oa_owner_pubkey"] as String?) != nil {
            attestedAgents.insert(pubkey)
        }

        var entities: [String: DirectoryEntity] = [:]
        var scope = Set(rosters.values.joined())
            .union(agentNames.keys)
            .union(attestedAgents)
        // Present even with no profile behind them, exactly as a roster member with no
        // kind-0 is: an entity with nothing in it renders as the monogram either way, and
        // one rule for "in scope" is easier to keep true than two.
        if let identity { scope.insert(identity) }
        for pubkey in scope {
            let profile = profiles[pubkey]
            entities[pubkey] = DirectoryEntity(
                pubkey: pubkey,
                profileName: nonempty(profile?["display_name"]),
                agentName: agentNames[pubkey] ?? nil,
                picture: nonempty(profile?["picture"]),
                nip05: nonempty(profile?["nip05"]),
                isAgent: botRoles.contains(pubkey) || attestedAgents.contains(pubkey)
            )
        }
        return DirectorySnapshot(entities: entities, memberPubkeysByChannel: rosters)
    }

    /// The kind-0 rows worth having, keyed by lowercased pubkey.
    ///
    /// Two statements, and the second is the whole point. The first is scoped to
    /// `channel_member ∪ agent_directory ∪ attested` so a relay-wide `profile` projection
    /// is not pulled into memory for identities no surface can show; the second fetches
    /// `identity`'s own row by primary key, because the reader is a surface — the
    /// account button — that the scope rule cannot see.
    ///
    /// The attested arm is what keeps an agent visible when it holds a verified owner
    /// attestation but has not landed in a roster this device has yet.
    private static func profileRows(_ db: Database, identity: String?) throws -> [String: Row] {
        var profiles: [String: Row] = [:]
        let scoped = try Row.fetchAll(db, sql: """
        SELECT pubkey, display_name, picture, nip05, oa_owner_pubkey
        FROM profile
        WHERE pubkey IN (
            SELECT pubkey FROM channel_member
            UNION SELECT pubkey FROM agent_directory
        )
           OR oa_owner_pubkey IS NOT NULL
        """)
        for row in scoped {
            profiles[(row["pubkey"] as String).lowercased()] = row
        }
        if let identity, profiles[identity] == nil {
            profiles[identity] = try Row.fetchOne(
                db,
                sql: """
                SELECT pubkey, display_name, picture, nip05, oa_owner_pubkey
                FROM profile WHERE pubkey = ?
                """,
                arguments: [identity]
            )
        }
        return profiles
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
