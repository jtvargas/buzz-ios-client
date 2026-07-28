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
    /// What this message's `imeta` tags (NIP-92) describe, in the order they were
    /// authored.
    ///
    /// # Why the row carries it instead of the renderer parsing tags
    ///
    /// These are *descriptions*, not a list of things to draw. A reference client
    /// positions an attachment where its URL appears in the message text and looks the
    /// `imeta` up by that URL, so what the renderer needs is an answer to "what is known
    /// about this URL" at the moment it meets one — which is a lookup over an already
    /// parsed list, not a tag scan per render.
    ///
    /// Parsed here, once per read, rather than by whatever draws the message: a
    /// conversation re-renders on every profile change and every arriving event, and
    /// re-parsing a JSON tag array on each of those is work with a known answer. It also
    /// keeps the row the whole truth about a message — the renderer never reaches back
    /// past it into the log.
    ///
    /// Empty for a message with no attachments, which is nearly all of them.
    public let media: [MessageMedia]

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
        lastReplyAt: Int64?,
        media: [MessageMedia] = []
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
        self.media = media
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
}
