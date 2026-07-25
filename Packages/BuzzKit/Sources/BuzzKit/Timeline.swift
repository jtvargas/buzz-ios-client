import Foundation
import GRDB
import NostrCore

/// One message as a reader needs it: content already resolved through the newest
/// authorized edit, deletion applied, delivery state and author profile joined in.
///
/// A timeline is not a materialized table. It is this row shape, assembled by a
/// query over the append-only log joined to its projections and unioned with the
/// pending outbox — so a projection fix never has to rewrite a message table, and
/// an optimistic send sorts into place by its own timestamp instead of living in a
/// second list that disagrees with the first.
public struct TimelineRow: Sendable, Hashable, Identifiable {
    public let id: String
    public let pubkey: String
    public let createdAt: Int64
    /// The current text: the newest authorized edit's content when one exists,
    /// otherwise the original.
    public let content: String
    public let isEdited: Bool
    /// Whether an authorized deletion applies. The row survives so the UI can
    /// render "message deleted" in place rather than leaving a hole.
    public let isDeleted: Bool
    /// Buzz kind 40002 payload, absent on relays that do not implement it; the
    /// renderer falls back to ``content``.
    public let richContent: String?
    /// Where this message is on its way to the relay.
    public let delivery: Delivery
    public let authorName: String?
    public let authorPicture: String?
    /// The message this one replies to directly, when it is a reply.
    public let parentID: String?
    /// The message that opened this reply's thread.
    public let rootID: String?
    /// How many non-deleted replies hang off this message.
    public let replyCount: Int
    /// When the newest non-deleted reply landed, for "last reply 5m ago".
    public let lastReplyAt: Int64?

    public init(
        id: String,
        pubkey: String,
        createdAt: Int64,
        content: String,
        isEdited: Bool,
        isDeleted: Bool,
        richContent: String?,
        delivery: Delivery,
        authorName: String?,
        authorPicture: String?,
        parentID: String?,
        rootID: String?,
        replyCount: Int,
        lastReplyAt: Int64?
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.content = content
        self.isEdited = isEdited
        self.isDeleted = isDeleted
        self.richContent = richContent
        self.delivery = delivery
        self.authorName = authorName
        self.authorPicture = authorPicture
        self.parentID = parentID
        self.rootID = rootID
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
    }

    public var isReply: Bool { parentID != nil }
    public var hasThread: Bool { replyCount > 0 }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(createdAt)) }

    public var lastReplyDate: Date? {
        lastReplyAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
    }

    /// A display name, falling back to a short form of the key.
    ///
    /// Deliberately not the raw npub: a first-time user should never have to reason
    /// about keys, and a truncated hex reads as an identifier rather than as
    /// something they are meant to understand.
    public var displayName: String {
        if let authorName, !authorName.isEmpty { return authorName }
        return String(pubkey.prefix(8))
    }
}

/// Where a message is on its journey to the relay.
public enum Delivery: Sendable, Hashable {
    /// Written to the log, which means the relay accepted it.
    case sent
    /// Signed and queued, waiting on the relay's OK.
    case pending
    /// Rejected or failed to send. Carries the reason when there is one worth
    /// showing.
    case failed(String?)

    /// Maps an outbox row's `state`/`last_error` onto a delivery state. A row that
    /// is not in the outbox at all reaches here as the `sent` sentinel the event
    /// branch selects. Exhaustive over ``OutboxState`` so a new queue state is a
    /// compile error here, not a silently mis-rendered message.
    init(state: String, lastError: String?) {
        switch OutboxState(rawValue: state) {
        case .pending, .sending, .awaitingReauth: self = .pending
        case .failed: self = .failed(lastError)
        case nil: self = .sent
        }
    }
}

/// A position in a channel's history.
///
/// Ordering is `(created_at, id)`, not `created_at` alone: relays hand out many
/// events in the same second, and a timestamp-only cursor either skips or repeats
/// them depending on which side of the boundary they land.
public struct TimelineCursor: Sendable, Equatable {
    public let createdAt: Int64
    public let id: String

    public init(createdAt: Int64, id: String) {
        self.createdAt = createdAt
        self.id = id
    }

    public init(row: TimelineRow) {
        self.init(createdAt: row.createdAt, id: row.id)
    }
}

public extension BuzzEventStore {
    /// A page of a channel's history, newest first.
    ///
    /// Log rows and pending outbox rows are unioned in one statement so an
    /// optimistic send sorts into place by its own timestamp. Keeping them in
    /// separate lists is the usual source of send bugs, where the two disagree
    /// about order or a message flickers twice during the pending→sent handover.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the
    /// actor, and so `ValueObservation` can track the tables it touches.
    nonisolated func timeline(
        channel: String,
        before cursor: TimelineCursor? = nil,
        limit: Int = 50
    ) throws -> [TimelineRow] {
        try reader.read { db in
            try Self.fetchTimeline(db, channel: channel, before: cursor, limit: limit)
        }
    }

    /// A whole thread: the message that opened it, then every reply, oldest first
    /// because a thread is read forwards.
    nonisolated func thread(root: String) throws -> [TimelineRow] {
        try reader.read { db in try Self.fetchThread(db, root: root) }
    }
}

extension BuzzEventStore {
    /// The channel page query, over an open database so an observation can track it.
    static func fetchTimeline(
        _ db: Database,
        channel: String,
        before cursor: TimelineCursor?,
        limit: Int
    ) throws -> [TimelineRow] {
        // Thread replies are excluded and shown in their thread instead; without
        // this a threaded conversation reads as a flat pile. A broadcast reply
        // keeps its `thread` row but is deliberately let through — its author
        // echoed it here.
        let sql = """
        SELECT \(timelineColumns)
        FROM (
            \(eventBranch(where: """
                e.h = :channel AND e.kind = :kind AND \(page("e.created_at", "e.id"))
                  AND NOT EXISTS (
                        SELECT 1 FROM thread tx
                        WHERE tx.event_id = e.id AND tx.broadcast = 0
                      )
                """))

            UNION ALL

            \(outboxBranch(where: """
                o.channel_id = :channel AND o.parent_id IS NULL
                  AND \(page("o.created_at", "o.event_id"))
                """))
        )
        ORDER BY created_at DESC, id DESC
        LIMIT :limit
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            "channel": channel,
            "kind": EventKind.channelMessage.rawValue,
            "hasCursor": cursor == nil ? 0 : 1,
            "ts": cursor?.createdAt ?? 0,
            "id": cursor?.id ?? "",
            "limit": limit,
        ])
        return makeRows(rows)
    }

    /// The thread query: the opener, its replies, and any pending replies.
    static func fetchThread(_ db: Database, root: String) throws -> [TimelineRow] {
        let sql = """
        SELECT \(timelineColumns)
        FROM (
            \(eventBranch(where: "e.id = :root AND e.kind = :kind"))

            UNION ALL

            \(eventBranch(where: """
                e.kind = :kind AND EXISTS (
                    SELECT 1 FROM thread tr
                    WHERE tr.event_id = e.id AND tr.root_id = :root
                )
                """))

            UNION ALL

            \(outboxBranch(where: "o.root_id = :root"))
        )
        ORDER BY created_at ASC, id ASC
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            "root": root,
            "kind": EventKind.channelMessage.rawValue,
        ])
        return makeRows(rows)
    }

    // MARK: - Shared query pieces

    /// One column list so the two branches and the outer select cannot drift.
    private static let timelineColumns = """
    id, pubkey, created_at, content, edited, deleted, rich,
    display_name, picture, parent_id, root_id, reply_count, last_reply_at,
    state, last_error
    """

    /// The keyset paging predicate over a `(created_at, id)` cursor. Descending id
    /// in the tiebreak so it matches the query's `ORDER BY … id DESC`.
    private static func page(_ timestamp: String, _ identifier: String) -> String {
        """
        (:hasCursor = 0
         OR \(timestamp) < :ts
         OR (\(timestamp) = :ts AND \(identifier) < :id))
        """
    }

    /// A message from the log, with its author, edits, deletion state, and thread
    /// position resolved.
    ///
    /// Authority is applied here, at read time, not at ingest. The projector stored
    /// every edit and deletion without judging it; this is where the judgment
    /// lands, because it needs the target's author (`e.pubkey`) and, for an
    /// agent-authored message, its verified NIP-OA owner (`eo.owner_pubkey`). A
    /// hosted Buzz relay enforces the same rules server-side; a plain NIP-29 relay
    /// may not, and without these predicates any member there could rewrite or
    /// blank another member's messages on every screen.
    ///
    /// The reply tallies exclude deleted replies, so a thread whose only reply was
    /// removed stops advertising one.
    private static func eventBranch(where predicate: String) -> String {
        """
        SELECT e.id                AS id,
               e.pubkey            AS pubkey,
               e.created_at        AS created_at,
               e.content           AS content,
               (SELECT ed.content FROM edit ed
                 WHERE ed.target_id = e.id
                   AND (ed.pubkey = e.pubkey OR ed.pubkey = eo.owner_pubkey)
                 ORDER BY ed.created_at DESC, ed.event_id DESC
                 LIMIT 1)          AS edited,
               \(deletionApplies(target: "e.id", author: "e.pubkey", owner: "eo.owner_pubkey")) AS deleted,
               rc.payload          AS rich,
               p.display_name      AS display_name,
               p.picture           AS picture,
               t.parent_id         AS parent_id,
               t.root_id           AS root_id,
               (SELECT COUNT(*) FROM thread tc
                 WHERE tc.root_id = e.id
                   AND NOT \(deletionApplies(
                       target: "tc.event_id",
                       author: "tc.pubkey",
                       owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = tc.event_id)"
                   ))) AS reply_count,
               (SELECT MAX(tl.created_at) FROM thread tl
                 WHERE tl.root_id = e.id
                   AND NOT \(deletionApplies(
                       target: "tl.event_id",
                       author: "tl.pubkey",
                       owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = tl.event_id)"
                   ))) AS last_reply_at,
               'sent'              AS state,
               NULL                AS last_error
        FROM event e
        LEFT JOIN rich_content rc ON rc.target_id = e.id
        LEFT JOIN profile p ON p.pubkey = e.pubkey
        LEFT JOIN thread t ON t.event_id = e.id
        LEFT JOIN event_owner eo ON eo.event_id = e.id
        WHERE \(predicate)
        """
    }

    /// The read-time deletion-authority predicate, widened per NIP-OA.
    ///
    /// A target renders deleted when a deletion names it and that deletion is
    /// authorized: a kind-9005 relay tombstone from anyone the relay accepted, the
    /// target author's own kind-5, or a kind-5 from the target author's verified
    /// owner. `owner` is the SQL expression yielding that owner pubkey, or NULL
    /// when the target carries no verified attestation — in which case the owner
    /// clause is a comparison against NULL and never matches.
    ///
    /// Internal rather than private so the channel-list read
    /// (``fetchChannelList(_:)``) applies the *same* authority when it excludes a
    /// deleted newest message, instead of forking a second predicate that could
    /// drift from this one.
    static func deletionApplies(target: String, author: String, owner: String) -> String {
        """
        EXISTS (
            SELECT 1 FROM deletion d
             WHERE d.target_id = \(target)
               AND (d.kind = \(EventKind.groupDeleteEvent.rawValue)
                    OR d.deleted_by = \(author)
                    OR d.deleted_by = \(owner))
        )
        """
    }

    /// A message signed and queued but not yet acknowledged by the relay. It
    /// carries no reply tally: nothing can have replied to it yet.
    ///
    /// A pending row is excluded the moment its event lands in the log — the two
    /// share an id, so once the log holds it (a relay echo that beat the OK, or the
    /// relaunch reconcile that stored it before the drain confirmed — the T3
    /// recovery state) the event branch renders it as `.sent` and this branch must
    /// not render a second, `.pending` copy of the same message.
    private static func outboxBranch(where predicate: String) -> String {
        """
        SELECT o.event_id  AS id,
               o.pubkey    AS pubkey,
               o.created_at AS created_at,
               o.content   AS content,
               NULL        AS edited,
               0           AS deleted,
               NULL        AS rich,
               p.display_name AS display_name,
               p.picture      AS picture,
               o.parent_id AS parent_id,
               o.root_id   AS root_id,
               0           AS reply_count,
               NULL        AS last_reply_at,
               o.state     AS state,
               o.last_error AS last_error
        FROM outbox o
        LEFT JOIN profile p ON p.pubkey = o.pubkey
        WHERE NOT EXISTS (SELECT 1 FROM event WHERE event.id = o.event_id)
          -- Messages only: a queued reaction or withdrawal rides the same durable
          -- outbox but must never render as a pending message. `:kind` is the
          -- channel-message kind both timeline callers already bind.
          AND o.kind = :kind
          AND (\(predicate))
        """
    }

    private static func makeRows(_ rows: [Row]) -> [TimelineRow] {
        rows.map(makeRow)
    }

    private static func makeRow(_ row: Row) -> TimelineRow {
        let edited: String? = row["edited"]
        return TimelineRow(
            id: row["id"],
            pubkey: row["pubkey"],
            createdAt: row["created_at"],
            content: edited ?? row["content"],
            isEdited: edited != nil,
            isDeleted: row["deleted"] ?? false,
            richContent: row["rich"],
            delivery: Delivery(state: row["state"], lastError: row["last_error"]),
            authorName: row["display_name"],
            authorPicture: row["picture"],
            parentID: row["parent_id"],
            rootID: row["root_id"],
            replyCount: row["reply_count"] ?? 0,
            lastReplyAt: row["last_reply_at"]
        )
    }
}
