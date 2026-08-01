import Foundation
import GRDB
import NostrCore

/// Relay-authoritative visibility for one identity and channel.
///
/// Cached metadata and messages deliberately outlive this value. They make an
/// already-open conversation useful offline, but they never make it visible in
/// the sidebar or writable.
public enum ChannelAccessState: String, Codable, Sendable, Hashable, CaseIterable {
    case active
    /// A direct message this identity has hidden from their own sidebar (NIP-DV).
    ///
    /// The odd one out: every other non-`active` state is a loss of access, and takes
    /// the conversation read-only. This one is *presentation*. The relay still counts
    /// you as an active participant, still delivers, and still lets you write — hiding
    /// a DM is how you clear it off your list without leaving it, and re-opening the DM
    /// (kind 41010) brings it straight back. So it keeps ``isWritable``, and the only
    /// thing it changes is that ``BuzzEventStore/activeChannelIDs(identity:)`` stops
    /// listing it.
    case hidden
    case archived
    case notMember
    case unavailable
    case deleted

    /// Whether the relay will accept what this identity writes here.
    ///
    /// A hidden DM is writable: hiding is a sidebar choice, not a lock, and telling
    /// someone their own conversation is read-only would be a lie the relay would
    /// immediately contradict.
    public var isWritable: Bool { self == .active || self == .hidden }
}

public struct ChannelAccessRecord: Sendable, Hashable {
    public let identityPubkey: String
    public let channelID: String
    public let state: ChannelAccessState
    public let updatedAt: Int64
}

/// A complete directory result. The client builds this value off-store; only a
/// complete result is eligible for the store's single atomic commit.
public struct ChannelDirectorySnapshot: Sendable {
    public let events: [NostrEvent]
    public let states: [String: ChannelAccessState]

    public init(events: [NostrEvent], states: [String: ChannelAccessState]) {
        self.events = events
        self.states = states
    }
}

public struct ChannelLifecyclePermissions: Sendable, Hashable {
    public let canArchive: Bool
    public let canDelete: Bool

    public init(canArchive: Bool, canDelete: Bool) {
        self.canArchive = canArchive
        self.canDelete = canDelete
    }

    public static let none = ChannelLifecyclePermissions(canArchive: false, canDelete: false)
}

public enum ChannelAccessError: Error, Equatable {
    case rejectedDirectoryEvents([String])
}

public extension BuzzEventStore {
    /// Reserves the next durable directory generation. A later request can reserve
    /// while this one is in flight; the older result will then fail its transaction
    /// guard and cannot overwrite the newer request's state.
    func beginChannelDirectoryRefresh(identity: String) async throws -> Int64 {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO channel_directory_request (identity_pubkey, generation)
                VALUES (?, 1)
                ON CONFLICT(identity_pubkey) DO UPDATE SET
                    generation = channel_directory_request.generation + 1
                """,
                arguments: [identity]
            )
            return try Int64.fetchOne(
                db,
                sql: "SELECT generation FROM channel_directory_request WHERE identity_pubkey = ?",
                arguments: [identity]
            ) ?? 1
        }
    }

    /// Seeds an upgraded store once from the current roster. This prevents a blank
    /// offline sidebar during the first launch after upgrading, while avoiding the
    /// old behavior of exposing every public channel cached in `channel`.
    func seedChannelAccessIfNeeded(identity: String) async throws {
        let key = "channel_access_seeded:\(identity)"
        let now = Int64(clock().timeIntervalSince1970)
        try await writer.write { db in
            guard try String.fetchOne(
                db,
                sql: "SELECT value FROM meta WHERE key = ?",
                arguments: [key]
            ) == nil else { return }

            try db.execute(
                sql: """
                INSERT INTO channel_access (identity_pubkey, channel_id, state, updated_at)
                SELECT ?, cm.channel_id,
                       CASE WHEN COALESCE(c.is_archived, 0) = 1 THEN ? ELSE ? END,
                       ?
                  FROM channel_member cm
                  LEFT JOIN channel c ON c.id = cm.channel_id
                 WHERE cm.pubkey = ?
                ON CONFLICT(identity_pubkey, channel_id) DO NOTHING
                """,
                arguments: [
                    identity,
                    ChannelAccessState.archived.rawValue,
                    ChannelAccessState.active.rawValue,
                    now,
                    identity,
                ]
            )
            try db.execute(
                sql: "INSERT INTO meta (key, value) VALUES (?, '1') ON CONFLICT(key) DO UPDATE SET value = '1'",
                arguments: [key]
            )
        }
    }

    /// Replaces the identity's authoritative directory in one transaction after
    /// every event has passed the same verification choke point as normal ingest.
    /// A rejected event aborts before the write, preserving the last good snapshot.
    @discardableResult
    func applyChannelDirectorySnapshot(
        _ snapshot: ChannelDirectorySnapshot,
        identity: String,
        generation: Int64? = nil
    ) async throws -> Bool {
        let (writable, result) = await Self.admit(snapshot.events)
        guard result.rejected.isEmpty else {
            throw ChannelAccessError.rejectedDirectoryEvents(result.rejected.map(\.id))
        }

        let receivedAt = Int64(clock().timeIntervalSince1970)
        let projector = projector
        let states = snapshot.states
        return try await writer.write { db in
            if let generation {
                let current = try Int64.fetchOne(
                    db,
                    sql: "SELECT generation FROM channel_directory_request WHERE identity_pubkey = ?",
                    arguments: [identity]
                )
                guard current == generation else { return false }
            }
            _ = try Self.writeAdmitted(
                writable,
                receivedAt: receivedAt,
                projector: projector,
                into: db
            )

            // The snapshot covers the full active set plus every channel that was
            // active in the previous good snapshot. Rows outside that set are
            // already inactive and may remain cached as-is.
            for (channelID, state) in states {
                try db.execute(
                    sql: """
                    INSERT INTO channel_access (identity_pubkey, channel_id, state, updated_at)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(identity_pubkey, channel_id) DO UPDATE SET
                        state = CASE
                            WHEN channel_access.state = ? THEN channel_access.state
                            ELSE excluded.state
                        END,
                        updated_at = excluded.updated_at
                    """,
                    arguments: [
                        identity,
                        channelID,
                        state.rawValue,
                        receivedAt,
                        ChannelAccessState.deleted.rawValue,
                    ]
                )
            }
            return true
        }
    }

    func markChannelAccess(
        identity: String,
        channel: String,
        state: ChannelAccessState
    ) async throws {
        let now = Int64(clock().timeIntervalSince1970)
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO channel_access (identity_pubkey, channel_id, state, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(identity_pubkey, channel_id) DO UPDATE SET
                    state = CASE
                        WHEN channel_access.state = ? THEN channel_access.state
                        ELSE excluded.state
                    END,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    identity,
                    channel,
                    state.rawValue,
                    now,
                    ChannelAccessState.deleted.rawValue,
                ]
            )
        }
    }

    func activeChannelIDs(identity: String) async throws -> Set<String> {
        try await reader.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                SELECT ca.channel_id
                  FROM channel_access ca
                  JOIN channel c ON c.id = ca.channel_id
                 WHERE ca.identity_pubkey = ?
                   AND ca.state = ?
                   AND c.is_archived = 0
                """,
                arguments: [identity, ChannelAccessState.active.rawValue]
            ))
        }
    }

    /// Access rows this identity still holds a live relationship with, independent of
    /// the rebuildable metadata projection. These are the channels the next directory
    /// pass must re-check even if metadata has since vanished or arrived archived
    /// through another path.
    ///
    /// Hidden DMs are in here for the same reason: hiding is not leaving, so a hidden
    /// DM whose membership *does* later change still has to be able to reach
    /// `.notMember` rather than sit hidden forever.
    func previouslyActiveChannelIDs(identity: String) async throws -> Set<String> {
        try await reader.read { db in
            Set(try String.fetchAll(
                db,
                sql: """
                SELECT channel_id
                  FROM channel_access
                 WHERE identity_pubkey = ? AND state IN (?, ?)
                """,
                arguments: [
                    identity,
                    ChannelAccessState.active.rawValue,
                    ChannelAccessState.hidden.rawValue,
                ]
            ))
        }
    }

    nonisolated func channelAccessState(
        identity: String,
        channel: String
    ) throws -> ChannelAccessState? {
        try reader.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT state FROM channel_access WHERE identity_pubkey = ? AND channel_id = ?",
                arguments: [identity, channel]
            ).flatMap(ChannelAccessState.init(rawValue:))
        }
    }

    /// What `identity` may do to one message — see ``MessageAuthority`` for why edit and
    /// delete are two answers rather than one.
    ///
    /// Three reads, each answering exactly one of the facts the rule needs. The channel
    /// role reuses ``channelLifecyclePermissions(identity:channel:)``'s query verbatim,
    /// including its agent indirection: a human whose *agent* is the channel admin holds
    /// the admin's power, which is how the relay reads it too.
    ///
    /// Advisory, like every other permission read here. The relay decides.
    nonisolated func messageAuthority(
        identity: String,
        channel: String,
        message: String,
        author: String
    ) throws -> MessageAuthority {
        // The reader's own message. Case-insensitive because a pubkey reaches this app
        // from the relay, from a signer and from a tag, and only some of those normalise.
        let isAuthor = identity.caseInsensitiveCompare(author) == .orderedSame
        if isAuthor {
            // Short circuit: an author can always do both, so neither remaining read can
            // change the answer and a message surface asks this once per opened sheet.
            return MessageAuthority(canEdit: true, canDelete: true)
        }
        return try reader.read { db in
            // Does this identity own the agent that wrote *this* message? Keyed on the
            // message rather than on the author, because NIP-OA attestation is per event —
            // an agent's ownership is asserted by the events it signs, not by a directory
            // entry that might not exist here yet.
            let ownsAuthor = try Bool.fetchOne(
                db,
                sql: """
                SELECT EXISTS (
                    SELECT 1 FROM event_owner
                     WHERE event_id = ? AND owner_pubkey = ?
                )
                """,
                arguments: [message, identity]
            ) ?? false

            let roles = try Self.channelRoles(db, identity: identity, channel: channel)
            return MessageAuthority.resolve(
                isAuthor: false,
                ownsAuthor: ownsAuthor,
                isChannelAdmin: roles.contains("owner") || roles.contains("admin")
            )
        }
    }

    /// Every role `identity` holds in `channel`, directly or through an agent it owns.
    ///
    /// Extracted so the message-authority read and the lifecycle read cannot drift: they
    /// ask the same question of the same two rosters, and a second copy of this SQL would
    /// be a second place for "admin" to mean something slightly different.
    private static func channelRoles(
        _ db: Database,
        identity: String,
        channel: String
    ) throws -> [String] {
        try String.fetchAll(
            db,
            sql: """
            SELECT LOWER(COALESCE(subject.role, ''))
              FROM (
                    SELECT pubkey, role, channel_id FROM channel_admin
                    UNION ALL
                    SELECT pubkey, role, channel_id FROM channel_member
              ) subject
             WHERE subject.channel_id = ?
               AND (
                   subject.pubkey = ?
                   OR EXISTS (
                       SELECT 1
                         FROM event e
                         JOIN event_owner eo ON eo.event_id = e.id
                        WHERE e.pubkey = subject.pubkey
                          AND eo.owner_pubkey = ?
                   )
               )
            """,
            arguments: [channel, identity, identity]
        )
    }

    /// Local affordances are advisory. The relay still makes the final permission
    /// decision when it accepts or rejects the signed lifecycle command.
    nonisolated func channelLifecyclePermissions(
        identity: String,
        channel: String
    ) throws -> ChannelLifecyclePermissions {
        try reader.read { db in
            let roles = try Self.channelRoles(db, identity: identity, channel: channel)
            let isOwner = roles.contains("owner")
            let isAdmin = isOwner || roles.contains("admin")
            return ChannelLifecyclePermissions(canArchive: isAdmin, canDelete: isOwner)
        }
    }
}
