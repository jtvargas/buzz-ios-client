import Foundation
import GRDB

/// One channel as a browse surface lists it — joined or merely discoverable.
///
/// # Why this is a query result and not a new table
///
/// Everything here is already in the store. The directory pass fetches kind 39000 and
/// 39002 for *every* channel the relay is willing to show this key, not only the ones
/// whose roster names them (see
/// ``ChannelDirectoryClient/fetch(selfPubkey:previouslyActiveChannels:)``), and
/// ``BuzzEventStore/applyChannelDirectorySnapshot(_:identity:generation:)`` admits them
/// through the same choke point as any other event. So `channel` already holds the name,
/// description, topic and archived flag of a channel nobody has joined, and
/// `channel_member` already holds its roster. A browse screen needs a read, not a payload,
/// a table, or a ``Schema/projectionVersion`` bump.
///
/// Direct messages are excluded: a DM is a conversation with people, not a channel anyone
/// browses or joins, and the relay's own `channel_type` is what says so.
public struct BrowsableChannel: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String?
    public let about: String?
    public let topic: String?
    public let picture: String?
    /// How many keys the relay-signed roster names. `0` for a channel whose kind-39002
    /// has not landed, which is *unknown* rather than empty — a channel always has at
    /// least its creator.
    public let memberCount: Int
    /// Whether the relay-signed roster names this identity. Real membership, and the
    /// only thing a Join button should read.
    public let isJoined: Bool
    public let isArchived: Bool
    public let isPrivate: Bool

    public init(
        id: String,
        name: String?,
        about: String?,
        topic: String?,
        picture: String?,
        memberCount: Int,
        isJoined: Bool,
        isArchived: Bool,
        isPrivate: Bool
    ) {
        self.id = id
        self.name = name
        self.about = about
        self.topic = topic
        self.picture = picture
        self.memberCount = memberCount
        self.isJoined = isJoined
        self.isArchived = isArchived
        self.isPrivate = isPrivate
    }
}

public extension BuzzEventStore {
    /// Every channel this identity can see, joined or not, ordered by name.
    ///
    /// Synchronous and `nonisolated` for the same reason ``channelList(selfPubkey:)`` is:
    /// it runs on the concurrent reader off the actor, and `ValueObservation.tracking` can
    /// watch the `channel` and `channel_member` tables it reads, so a browse screen stays
    /// live as the directory pass commits.
    ///
    /// Unordered by activity on purpose. A browse list is a catalogue, and the surfaces
    /// that sort it — alphabetical, most members — sort the array they were handed rather
    /// than paying for a second query per sort order.
    nonisolated func browsableChannels(identity: String) throws -> [BrowsableChannel] {
        try reader.read { db in
            try Self.fetchBrowsableChannels(db, identity: identity)
        }
    }

    /// The channels whose relay-signed roster names `identity` — real membership, as
    /// distinct from what the relay is merely willing to *show* this key.
    ///
    /// This is the set the standing content subscriptions and the head reconcile scope
    /// to (``SyncEngine/reconcileChannelSubscriptions(_:)``). It reads the durable
    /// `channel_member` projection rather than `channel_access`, which is what makes it
    /// safe to reconcile *removals* against: a roster is replaced only by a newer kind
    /// 39002, never by one failing to arrive, so a discovery gap cannot narrow this set
    /// and tear down live subscriptions.
    nonisolated func joinedChannelIDs(identity: String) throws -> Set<String> {
        try reader.read { db in
            try Self.fetchJoinedChannelIDs(db, identity: identity)
        }
    }
}

extension BuzzEventStore {
    /// Membership over an open database, so an observation can track it.
    ///
    /// Compared exactly rather than case-insensitively, and against a lowercased
    /// parameter: `channel_member.pubkey` is stored as the relay wrote it, the relay
    /// hex-encodes lowercase, and `channel_member_pubkey` is a case-sensitive index that
    /// a `LOWER()` or `COLLATE NOCASE` comparison would decline to seek.
    static func fetchJoinedChannelIDs(_ db: Database, identity: String) throws -> Set<String> {
        Set(try String.fetchAll(
            db,
            sql: "SELECT channel_id FROM channel_member WHERE pubkey = ?",
            arguments: [identity.lowercased()]
        ))
    }

    /// The catalogue assembly, over an open database.
    ///
    /// Three statements rather than one join with a correlated `EXISTS` and a correlated
    /// `COUNT`: those would run twice per channel row, and the whole point of this read is
    /// that it is issued for a relay's entire channel list at once. Grouped once, joined in
    /// memory.
    static func fetchBrowsableChannels(
        _ db: Database,
        identity: String
    ) throws -> [BrowsableChannel] {
        var memberCounts: [String: Int] = [:]
        for row in try Row.fetchAll(
            db,
            sql: "SELECT channel_id, COUNT(*) AS n FROM channel_member GROUP BY channel_id"
        ) {
            memberCounts[row["channel_id"]] = row["n"]
        }
        let joined = try fetchJoinedChannelIDs(db, identity: identity)

        return try Row.fetchAll(db, sql: """
        SELECT id, name, about, topic, picture, is_archived, is_private
          FROM channel
         WHERE channel_type IS NULL OR channel_type <> 'dm'
         ORDER BY name COLLATE NOCASE ASC, id ASC
        """).map { row in
            let id: String = row["id"]
            return BrowsableChannel(
                id: id,
                name: row["name"],
                about: row["about"],
                topic: row["topic"],
                picture: row["picture"],
                memberCount: memberCounts[id] ?? 0,
                isJoined: joined.contains(id),
                isArchived: row["is_archived"] ?? false,
                isPrivate: row["is_private"] ?? false
            )
        }
    }
}
