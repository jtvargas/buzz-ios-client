import Foundation
import GRDB
import NostrCore

/// One channel as the channel list needs it: its metadata joined to a preview of
/// the newest message that is actually *visible* in it.
///
/// Like ``TimelineRow`` this is a query result, not a stored table. The "last
/// message" is recomputed from the append-only log and the pending outbox on every
/// read — resolved through the same read-time deletion authority the timeline
/// applies — so a deletion, an edit's arrival, or an optimistic send is reflected
/// without a preview column anyone has to keep in step. That is what lets a single
/// `ValueObservation` over this query keep the list live.
public struct ChannelListRow: Sendable, Hashable, Identifiable {
    /// The channel's group id — the `d` of its kind-39000 metadata, which is also
    /// the `h` its messages are scoped by.
    public let id: String
    public let name: String?
    public let about: String?
    public let picture: String?
    public let isPrivate: Bool
    /// When the newest visible message landed, or `nil` for a channel with none.
    /// The list orders on this, newest first, with the messageless channels last.
    public let lastMessageAt: Int64?
    /// The newest visible message's event id, used to resolve its own mention tags
    /// when the shared rich-text renderer draws the channel-list preview.
    public let lastMessageID: String?
    /// The newest visible message's raw content. The list UI truncates it; keeping
    /// it whole here means the row carries the same text the timeline would show.
    public let lastMessageSnippet: String?
    /// Who sent the newest visible message: the author's profile display name when
    /// one is known, otherwise the raw pubkey. Truncation and npub formatting are
    /// the UI's call, exactly as with the snippet.
    public let lastMessageAuthor: String?
    /// The newest visible message author's public key, always — whether or not a display
    /// name was found for it.
    ///
    /// Carried beside ``lastMessageAuthor`` rather than folded into it because a UI that
    /// wants to resolve the author through its own name chain needs the key, and
    /// recovering it from the collapsed column means guessing from shape: "64 hex
    /// characters, therefore a key" is wrong for a display name that happens to look like
    /// one, and the caller then renders a stranger's identifier. `nil` only for a channel
    /// with no visible message.
    public let lastMessageAuthorPubkey: String?
    /// How many top-level messages by *other* people are newer than this channel's
    /// read frontier — the NIP-RS unread count. Own posts never count, thread replies
    /// never count (they carry their own thread badges), and a channel no blob has
    /// ever marked read counts every such message (unknown state is unread, the
    /// conservative NIP-RS default). Zero when caught up.
    public let unreadCount: Int
    /// How many of those unread messages `p`-tag the local identity — the number behind
    /// the sidebar's mention badge.
    ///
    /// Counted over exactly the set ``unreadCount`` counts, so it can never exceed it: a
    /// badge reading `3` on a row holding two unread messages is arithmetic a reader
    /// notices immediately. A message that tags the same identity twice counts once.
    ///
    /// Zero without a local identity, which is the honest answer rather than a
    /// degradation — with no key there is nobody for a message to be addressed to.
    public let unreadMentionCount: Int

    public init(
        id: String,
        name: String?,
        about: String?,
        picture: String?,
        isPrivate: Bool,
        lastMessageAt: Int64?,
        lastMessageID: String? = nil,
        lastMessageSnippet: String?,
        lastMessageAuthor: String?,
        lastMessageAuthorPubkey: String? = nil,
        unreadCount: Int = 0,
        unreadMentionCount: Int = 0
    ) {
        self.id = id
        self.name = name
        self.about = about
        self.picture = picture
        self.isPrivate = isPrivate
        self.lastMessageAt = lastMessageAt
        self.lastMessageID = lastMessageID
        self.lastMessageSnippet = lastMessageSnippet
        self.lastMessageAuthor = lastMessageAuthor
        self.lastMessageAuthorPubkey = lastMessageAuthorPubkey
        self.unreadCount = unreadCount
        self.unreadMentionCount = unreadMentionCount
    }

    /// Whether the channel carries any unread messages — the bold-name / count-pill gate.
    public var hasUnread: Bool { unreadCount > 0 }

    public var hasMessages: Bool { lastMessageAt != nil }

    public var lastMessageDate: Date? {
        lastMessageAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }
}

public extension BuzzEventStore {
    /// Every channel, each carrying a preview of its newest visible message and its
    /// unread count, most-recently-active first and channels with no messages last.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation.tracking` can watch the `channel`, `event`,
    /// `outbox`, `deletion`, `event_owner`, `profile`, `thread`, and `read_state`
    /// tables it reads — the same discipline that lets
    /// ``timeline(channel:before:limit:)`` back a live view.
    ///
    /// - Parameter selfPubkey: the local identity's hex pubkey, so a channel's own
    ///   posts are excluded from its unread count. `nil` degrades to counting every
    ///   author (the keyless fallback), the same posture the timeline's own-row
    ///   affordances take.
    nonisolated func channelList(selfPubkey: String? = nil) throws -> [ChannelListRow] {
        try reader.read { db in try Self.fetchChannelList(db, selfPubkey: selfPubkey) }
    }
}

extension BuzzEventStore {
    /// The channel-list query, over an open database so an observation can track it.
    ///
    /// The heart is one `visible` set: kind-9 log messages that survive the
    /// read-time deletion predicate, unioned with pending outbox sends the log does
    /// not yet hold. From it, each channel keeps the single message no other visible
    /// message in that channel outranks on the `(created_at, id)` keyset — the same
    /// total order the timeline pages on, so "newest" means the same thing in both
    /// reads. A deleted newest message drops out of `visible` and the previous one
    /// wins; a pending send outranks the log until its own copy is ingested, at
    /// which point the outbox row is excluded and the log row takes its place with
    /// no double count.
    static func fetchChannelList(_ db: Database, selfPubkey: String? = nil) throws -> [ChannelListRow] {
        let rows = try Row.fetchAll(db, sql: channelListSQL, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
        ])
        return rows.map(makeChannelListRow)
    }

    /// The channel-list query. A stored constant so the deletion-predicate
    /// interpolation is resolved once, and so the fetch stays a short function over it.
    static let channelListSQL = """
        WITH visible AS (
            SELECT e.h          AS channel_id,
                   e.id         AS msg_id,
                   e.created_at AS created_at,
                   e.content    AS content,
                   e.pubkey     AS pubkey
            FROM event e
            LEFT JOIN event_owner eo ON eo.event_id = e.id
            WHERE e.kind = :kind
              AND e.h IS NOT NULL
              AND NOT \(deletionApplies(target: "e.id", author: "e.pubkey", owner: "eo.owner_pubkey"))

            UNION ALL

            SELECT o.channel_id AS channel_id,
                   o.event_id   AS msg_id,
                   o.created_at AS created_at,
                   o.content    AS content,
                   o.pubkey     AS pubkey
            FROM outbox o
            -- Messages only (`o.kind = :kind`), so a queued reaction never becomes a
            -- channel's "last message"; `:kind` is the channel-message kind bound below.
            WHERE NOT EXISTS (SELECT 1 FROM event WHERE event.id = o.event_id) AND o.kind = :kind
        ),
        -- The effective read frontier per channel: MAX(read_at) across every device's
        -- slot (the grow-only NIP-RS merge), so one device's stale slot can never lower
        -- another's frontier.
        frontier AS (
            SELECT context_id AS channel_id, MAX(read_at) AS read_at
            FROM read_state
            GROUP BY context_id
        ),
        -- Unread = top-level channel messages by OTHERS, newer than the frontier, not
        -- deleted. Thread replies (a `thread` row) are excluded — they carry their own
        -- badges. A channel with no frontier falls to COALESCE(…,0), so every such
        -- message counts (unknown read state is unread — the conservative NIP-RS default).
        unread AS (
            SELECT ue.h AS channel_id, COUNT(*) AS n
            FROM event ue
            LEFT JOIN event_owner ueo ON ueo.event_id = ue.id
            LEFT JOIN frontier uf ON uf.channel_id = ue.h
            WHERE ue.kind = :kind
              AND ue.h IS NOT NULL
              AND (:selfPubkey IS NULL OR ue.pubkey <> :selfPubkey)
              AND ue.created_at > COALESCE(uf.read_at, 0)
              AND NOT EXISTS (SELECT 1 FROM thread t WHERE t.event_id = ue.id)
              AND NOT \(deletionApplies(target: "ue.id", author: "ue.pubkey", owner: "ueo.owner_pubkey"))
            GROUP BY ue.h
        ),
        -- The subset of `unread` addressed to the local identity: same predicates, plus a
        -- `p` tag naming them. A second CTE over the same conditions rather than a
        -- conditional aggregate inside `unread`, because the tag join is what makes it
        -- cheap — it visits messages that carry a `p` tag rather than every unread message
        -- in the workspace. COUNT(DISTINCT) because a message may tag one identity twice
        -- and a badge counts messages, not tags. With `:selfPubkey` NULL the join matches
        -- nothing and every channel falls to zero.
        --
        -- `COLLATE NOCASE` on the tag value, deliberately, where `event.pubkey`
        -- comparisons elsewhere in this file are binary: a pubkey in the log went through
        -- NIP-01's strictly-lowercase hex decode, but a *tag value* is a raw string
        -- written by whichever client sent the message and never decoded. Missing a
        -- mention because another client upper-cased a key is the worse failure, and it
        -- is the case-insensitivity the sidebar's own `mentionsSelf` had before this
        -- column replaced it. Measured at 2.0 ms against 2.2 ms binary over a 50k-event
        -- store, so it costs nothing here — unlike on `event.pubkey`, where the same
        -- collation is the difference between 2 ms and 63 ms (see ``RecentMentions``).
        mentioned AS (
            SELECT me.h AS channel_id, COUNT(DISTINCT me.id) AS n
            FROM event me
            JOIN event_tag mt ON mt.event_id = me.id
                             AND mt.name = 'p'
                             AND mt.value = :selfPubkey COLLATE NOCASE
            LEFT JOIN event_owner meo ON meo.event_id = me.id
            LEFT JOIN frontier mf ON mf.channel_id = me.h
            WHERE me.kind = :kind
              AND me.h IS NOT NULL
              AND me.pubkey <> :selfPubkey
              AND me.created_at > COALESCE(mf.read_at, 0)
              AND NOT EXISTS (SELECT 1 FROM thread t WHERE t.event_id = me.id)
              AND NOT \(deletionApplies(target: "me.id", author: "me.pubkey", owner: "meo.owner_pubkey"))
            GROUP BY me.h
        )
        SELECT c.id            AS id,
               c.name          AS name,
               c.about         AS about,
               c.picture       AS picture,
               c.is_private    AS is_private,
               n.msg_id        AS last_message_id,
               n.created_at    AS last_message_at,
               n.content       AS last_message_snippet,
               n.pubkey        AS author_pubkey,
               p.display_name  AS author_name,
               COALESCE(u.n, 0) AS unread_count,
               COALESCE(m.n, 0) AS mention_count
        FROM channel c
        LEFT JOIN visible n
               ON n.channel_id = c.id
              AND NOT EXISTS (
                    SELECT 1 FROM visible n2
                     WHERE n2.channel_id = n.channel_id
                       AND (n2.created_at > n.created_at
                            OR (n2.created_at = n.created_at AND n2.msg_id > n.msg_id))
                  )
        LEFT JOIN unread u ON u.channel_id = c.id
        LEFT JOIN mentioned m ON m.channel_id = c.id
        LEFT JOIN profile p ON p.pubkey = n.pubkey
        ORDER BY last_message_at DESC NULLS LAST, c.name ASC, c.id ASC
        """

    private static func makeChannelListRow(_ row: Row) -> ChannelListRow {
        let authorPubkey: String? = row["author_pubkey"]
        let authorName: String? = row["author_name"]
        // Mirror ``TimelineRow/displayName``: a present-but-empty profile name is
        // not a name, so it falls back to the key rather than rendering blank.
        let author = authorPubkey.map { pubkey -> String in
            if let authorName, !authorName.isEmpty { return authorName }
            return pubkey
        }
        return ChannelListRow(
            id: row["id"],
            name: row["name"],
            about: row["about"],
            picture: row["picture"],
            isPrivate: row["is_private"] ?? false,
            lastMessageAt: row["last_message_at"],
            lastMessageID: row["last_message_id"],
            lastMessageSnippet: row["last_message_snippet"],
            lastMessageAuthor: author,
            lastMessageAuthorPubkey: authorPubkey,
            unreadCount: row["unread_count"] ?? 0,
            unreadMentionCount: row["mention_count"] ?? 0
        )
    }
}
