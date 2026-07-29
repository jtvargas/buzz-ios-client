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
    /// Every column is asked **per channel**. A channel's preview is the single message
    /// no other visible message in it outranks on the `(created_at, id)` keyset — the same
    /// total order the timeline pages on, so "newest" means the same thing in both reads.
    /// A deleted newest message drops out and the previous one wins; a pending send
    /// outranks the log until its own copy is ingested, at which point the queued row is
    /// excluded and the log row takes its place with no double count. The two counts are
    /// the same predicates measured from the same frontier.
    static func fetchChannelList(_ db: Database, selfPubkey: String? = nil) throws -> [ChannelListRow] {
        let rows = try Row.fetchAll(db, sql: channelListSQL, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
        ])
        return rows.map(makeChannelListRow)
    }

    /// The id of one channel's newest *visible* message: the log and the queue each
    /// bounded to their own newest row, then compared.
    ///
    /// Interpolated into ``channelListSQL`` inside a scope where `c` is the `channel` row,
    /// which is what makes it a probe rather than a scan: `e.h = c.id` and
    /// `o.channel_id = c.id` hand each branch a range of `event_timeline
    /// (h, kind, created_at DESC, id)` and `outbox_channel (channel_id, created_at)`, and
    /// `LIMIT 1` stops it at the first surviving row instead of building the channel.
    ///
    /// Messages only on the queue side (`o.kind = :kind`), so a queued reaction never
    /// becomes a channel's "last message". Thread replies are deliberately *not* excluded
    /// on either side — a reply the reader can see in the channel is the newest thing in
    /// it, and the sidebar says so.
    ///
    /// # Why bounding each branch cannot change the answer
    ///
    /// The winner is the maximum on the `(created_at, id)` keyset over the union of the
    /// two branches, and `max(A ∪ B) = max(max A, max B)` — so taking each branch's own
    /// maximum first picks the same row. That is ``fetchTimeline``'s page bound at N = 1,
    /// and it carries the same precondition, in three parts:
    ///
    /// 1. every branch orders by the same total order the outer pick uses —
    ///    `created_at DESC, id DESC` — on the columns it projects as `created_at` and
    ///    `msg_id`, not on columns that merely alias plausibly;
    /// 2. the same bound applies to every branch;
    /// 3. nothing between a branch's `LIMIT` and the outer pick removes a row.
    ///
    /// **None of the three fails loudly.** A branch ordered another way, or filtered after
    /// its bound, returns a plausible message rather than no message — and the sidebar
    /// quietly previews something that is not the newest thing in the channel. Anything
    /// added here inherits all three.
    private static let newestVisibleInChannel = """
    (SELECT w.msg_id FROM (
        SELECT * FROM (
            SELECT e.id AS msg_id, e.created_at AS created_at
            FROM event e
            LEFT JOIN event_owner eo ON eo.event_id = e.id
            WHERE e.h = c.id AND e.kind = :kind
              AND NOT \(deletionApplies(target: "e.id", author: "e.pubkey", owner: "eo.owner_pubkey"))
            ORDER BY e.created_at DESC, e.id DESC
            LIMIT 1
        )

        UNION ALL

        SELECT * FROM (
            SELECT o.event_id AS msg_id, o.created_at AS created_at
            FROM outbox o
            WHERE o.channel_id = c.id AND o.kind = :kind
              AND NOT EXISTS (SELECT 1 FROM event ev WHERE ev.id = o.event_id)
            ORDER BY o.created_at DESC, o.event_id DESC
            LIMIT 1
        )
    ) w
    ORDER BY w.created_at DESC, w.msg_id DESC
    LIMIT 1)
    """

    /// One channel's effective read frontier: `MAX(read_at)` across every device's slot
    /// (the grow-only NIP-RS merge), so one device's stale slot can never lower another's.
    /// `MAX` over no rows is NULL, so a channel no blob has ever marked read falls to 0 and
    /// every message in it counts — unknown read state is unread, the conservative NIP-RS
    /// default. Written once and used by both counts, because a badge counting from a
    /// different frontier than the row it sits on is arithmetic a reader notices.
    private static let channelFrontier = """
    COALESCE((SELECT MAX(read_at) FROM read_state WHERE context_id = c.id), 0)
    """

    /// The channel-list query. A stored constant so the deletion-predicate
    /// interpolation is resolved once, and so the fetch stays a short function over it.
    ///
    /// # One question per channel, not one row per message
    ///
    /// This read fires on every committed transaction (``ChannelListModel``), and it used
    /// to answer per *workspace*: a `visible` CTE materialising every surviving kind-9
    /// message anywhere, plus two more full passes for the counts, then an anti-join
    /// asking each of those rows whether a newer one existed. The cost was O(total log)
    /// to produce one row per channel — 51.7 ms against 8,860 events, and growing with
    /// every channel's history at once rather than with anything on screen.
    ///
    /// Every column is now a correlated probe keyed on `c.id`, so the work is bounded by
    /// the answer rather than by the log: **51.7 ms → 2.8 ms**, byte-identical result sets
    /// across the fixtures in `RESEARCH/SIDEBAR_READ_COST.md`, which is where the harness
    /// and the caveats live. The numbers are from a seeded fixture through the system
    /// SQLite, not from a device.
    static let channelListSQL = """
        WITH newest AS (
            SELECT c.id AS channel_id, \(newestVisibleInChannel) AS msg_id
            FROM channel c
        )
        SELECT c.id            AS id,
               c.name          AS name,
               c.about         AS about,
               c.picture       AS picture,
               c.is_private    AS is_private,
               n.msg_id        AS last_message_id,
               -- The winner is a log row or a queued row, never both — the queue branch
               -- excludes anything the log already holds — so the pair of joins below
               -- resolves exactly one of them and COALESCE reads it.
               COALESCE(le.created_at, lo.created_at) AS last_message_at,
               COALESCE(le.content, lo.content)       AS last_message_snippet,
               COALESCE(le.pubkey, lo.pubkey)         AS author_pubkey,
               p.display_name  AS author_name,
               -- Unread = top-level channel messages by OTHERS, newer than the frontier,
               -- not deleted. Thread replies (a `thread` row) are excluded here — unlike
               -- in the preview — because they carry their own thread badges.
               (SELECT COUNT(*)
                  FROM event ue
                  LEFT JOIN event_owner ueo ON ueo.event_id = ue.id
                 WHERE ue.h = c.id AND ue.kind = :kind
                   AND (:selfPubkey IS NULL OR ue.pubkey <> :selfPubkey)
                   AND ue.created_at > \(channelFrontier)
                   AND NOT EXISTS (SELECT 1 FROM thread t WHERE t.event_id = ue.id)
                   AND NOT \(deletionApplies(
                       target: "ue.id", author: "ue.pubkey", owner: "ueo.owner_pubkey"
                   ))) AS unread_count,
               -- The subset of those addressed to the local identity: the same predicates
               -- plus a `p` tag naming them, so the badge can never exceed the count it
               -- sits beside. COUNT(DISTINCT) because a message may tag one identity twice
               -- and a badge counts messages, not tags.
               --
               -- With no local identity every channel reads zero, which is the honest
               -- answer rather than a degradation: there is nobody for a message to be
               -- addressed to. **The join is what produces that** — `mt.value = NULL` is
               -- NULL, so it matches nothing. `me.pubkey <> :selfPubkey` is deliberately
               -- not the `IS NULL OR` form `unread` uses, but it is not what carries the
               -- keyless case and rewriting it to that form changes no answer; it is here
               -- to keep the reader's own mentions of themselves out of their own badge.
               --
               -- `COLLATE NOCASE` on the tag value, deliberately, where `event.pubkey`
               -- comparisons elsewhere in this file are binary: a pubkey in the log went
               -- through NIP-01's strictly-lowercase hex decode, but a *tag value* is a raw
               -- string written by whichever client sent the message and never decoded.
               -- Missing a mention because another client upper-cased a key is the worse
               -- failure. Measured at 2.0 ms against 2.2 ms binary over a 50k-event store,
               -- so it costs nothing here — unlike on `event.pubkey`, where the same
               -- collation is the difference between 2 ms and 63 ms (see ``RecentMentions``).
               (SELECT COUNT(DISTINCT me.id)
                  FROM event me
                  JOIN event_tag mt ON mt.event_id = me.id
                                   AND mt.name = 'p'
                                   AND mt.value = :selfPubkey COLLATE NOCASE
                  LEFT JOIN event_owner meo ON meo.event_id = me.id
                 WHERE me.h = c.id AND me.kind = :kind
                   AND me.pubkey <> :selfPubkey
                   AND me.created_at > \(channelFrontier)
                   AND NOT EXISTS (SELECT 1 FROM thread t WHERE t.event_id = me.id)
                   AND NOT \(deletionApplies(
                       target: "me.id", author: "me.pubkey", owner: "meo.owner_pubkey"
                   ))) AS mention_count
        FROM channel c
        LEFT JOIN newest n ON n.channel_id = c.id
        LEFT JOIN event le ON le.id = n.msg_id
        -- Only when the winner is not a log row: a send stays in the queue after its event
        -- lands, so without this a settled message would match on both sides.
        --
        -- It changes no answer *today* — `COALESCE` already prefers `le`, and
        -- `outbox.event_id` is a primary key so the join cannot duplicate the row — and
        -- removing it is a mutation nothing here catches. It stays because the moment a
        -- column only the queue carries is read (`lo.state` for a sending chip, say), a
        -- settled message starts reading as in-flight, and that failure would arrive
        -- attached to the new column rather than to this join.
        LEFT JOIN outbox lo ON lo.event_id = n.msg_id AND le.id IS NULL
        LEFT JOIN profile p ON p.pubkey = COALESCE(le.pubkey, lo.pubkey)
        LEFT JOIN channel_access ca
          ON ca.channel_id = c.id AND ca.identity_pubkey = :selfPubkey
        WHERE :selfPubkey IS NULL
           OR NOT EXISTS (
               SELECT 1 FROM meta
                WHERE key = 'channel_access_seeded:' || :selfPubkey
           )
           OR (ca.state = 'active' AND c.is_archived = 0)
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
