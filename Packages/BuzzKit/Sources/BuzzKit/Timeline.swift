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
    public let failureIsRetryable: Bool
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

    /// How many of ``media`` are already stored on the relay, while this row is still
    /// on its way — the numerator of the pending row's "Sending… (2/5)".
    ///
    /// Meaningful only for a `.pending` row carrying media. A delivered row names only
    /// pictures the relay already holds, so the query supplies 0 there rather than
    /// counting: the answer would always equal ``media`` and nothing reads it.
    public let uploadedMediaCount: Int

    /// What the relay narrated here, when this row is a kind-40099 channel notice
    /// rather than something a person wrote.
    ///
    /// A notice rides the same query as a message so that paging stays honest: the page
    /// is a `LIMIT` over a `(created_at, id)` keyset, and a second list merged in
    /// afterwards could not know how many of its own rows fall inside a page without
    /// re-reading the same window. One query, one order, one cursor.
    ///
    /// `nil` for every message, which is nearly every row. When it is non-`nil`,
    /// ``content`` is the notice's raw JSON body and must never be shown — the grouping
    /// step turns these into their own conversation item precisely so no message
    /// renderer is ever handed one.
    ///
    /// It is also `nil` for a notice this build cannot read: a type added to the relay
    /// since, or a body naming nobody. ``isNotice`` is what tells those apart, and it is
    /// the reason the two are separate properties — a row that is a notice but decoded
    /// to nothing must be dropped, not rendered as a message whose text is JSON.
    public let notice: SystemNotice?

    /// Whether this row is a relay notice at all, decodable or not.
    public let isNotice: Bool

    /// Whether this message names the reader — a `p` tag carrying their key, on a
    /// message somebody else wrote.
    ///
    /// # Why the row carries it rather than a surface asking
    ///
    /// Because the conversation's *grouping* reads it, and grouping has to be a pure
    /// function of the rows or it flickers. A message's mentions are also available as
    /// ``BuzzEventStore/mentions(for:)``, which is what resolves the `@`-tokens inside the
    /// text — but that read lands on the surface **after** the rows do, so a run regrouped
    /// when it arrived: the message would stack, then split out a moment later. Carried
    /// here it arrives with the row it describes, and the group is right the first time.
    ///
    /// `false` for the reader's own messages, including their own pending sends: this app
    /// strips the sender from a message's own `p` tags (`OutboundTags`), and a mention of
    /// yourself is not a thing to be told about anyway.
    ///
    /// An edit can add this and cannot take it away — deliberately unlike ``media``, which
    /// reads the edit's tags alone. `OutboundTags.edit` sends `h` and `e` and nothing else,
    /// so an edit from this app can never carry a `p` tag; treating its absence as "you are
    /// no longer named" would read an intention out of a shape that cannot express one, and
    /// would disagree with every other reader of the same fact — `event_tag` is insert-only,
    /// so the mention badge and the `@`-token in the text both still see the original.
    public let namesSelf: Bool

    public init(
        id: String,
        pubkey: String,
        createdAt: Int64,
        content: String,
        isEdited: Bool,
        isDeleted: Bool,
        richContent: String?,
        delivery: Delivery,
        failureIsRetryable: Bool = false,
        authorName: String?,
        authorPicture: String?,
        parentID: String?,
        rootID: String?,
        replyCount: Int,
        lastReplyAt: Int64?,
        media: [MessageMedia] = [],
        uploadedMediaCount: Int = 0,
        notice: SystemNotice? = nil,
        isNotice: Bool = false,
        namesSelf: Bool = false
    ) {
        self.id = id
        self.pubkey = pubkey
        self.createdAt = createdAt
        self.content = content
        self.isEdited = isEdited
        self.isDeleted = isDeleted
        self.richContent = richContent
        self.delivery = delivery
        self.failureIsRetryable = failureIsRetryable
        self.authorName = authorName
        self.authorPicture = authorPicture
        self.parentID = parentID
        self.rootID = rootID
        self.replyCount = replyCount
        self.lastReplyAt = lastReplyAt
        self.media = media
        self.uploadedMediaCount = uploadedMediaCount
        self.notice = notice
        // A decoded notice is a notice, whatever the caller passed: the two cannot
        // disagree, and a test that builds one by hand should not have to say so twice.
        self.isNotice = isNotice || notice != nil
        self.namesSelf = namesSelf
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
        case .pending, .sending, .awaitingMedia, .awaitingReauth: self = .pending
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
        limit: Int = 50,
        selfPubkey: String? = nil
    ) throws -> [TimelineRow] {
        try reader.read { db in
            try Self.fetchTimeline(
                db, channel: channel, before: cursor, limit: limit, selfPubkey: selfPubkey
            )
        }
    }

    /// A whole thread: the message that opened it, then every reply, oldest first
    /// because a thread is read forwards.
    nonisolated func thread(root: String, selfPubkey: String? = nil) throws -> [TimelineRow] {
        try reader.read { db in try Self.fetchThread(db, root: root, selfPubkey: selfPubkey) }
    }
}

extension BuzzEventStore {
    /// The channel page query, over an open database so an observation can track it.
    static func fetchTimeline(
        _ db: Database,
        channel: String,
        before cursor: TimelineCursor?,
        limit: Int,
        selfPubkey: String? = nil
    ) throws -> [TimelineRow] {
        // Thread replies are excluded and shown in their thread instead; without
        // this a threaded conversation reads as a flat pile. A broadcast reply
        // keeps its `thread` row but is deliberately let through — its author
        // echoed it here.
        //
        // Relay notices (kind 40099) come from the same query as the messages, because
        // they interleave with them by time and a page is a `LIMIT` over the
        // `(created_at, id)` keyset — a second list merged afterwards could not know how
        // many of its own rows belong inside a page without re-reading the same window.
        // The joins around a notice all miss harmlessly: it has no edit, no rich
        // content, no thread row and no author profile, so it comes back with the empty
        // defaults and ``makeRow(_:)`` decodes its body into ``TimelineRow/notice``.
        //
        // # Why every branch carries its own `ORDER BY` and `LIMIT`
        //
        // A `UNION ALL` is not a merge. SQLite materialises the compound as a co-routine,
        // scans it whole and sorts the result — so the outer `LIMIT` applies *after* every
        // message in the channel has been built and ordered, and the page read costs
        // O(channel history) rather than O(page). That has been true since the outbox
        // branch introduced the union, long before notices.
        //
        // Bounding each branch restores the early stop without changing what comes back,
        // because a row in the global newest `limit` is necessarily in the newest `limit`
        // of whichever branch it came from:
        //
        //     top-N(A ∪ B ∪ C) ⊆ top-N(A) ∪ top-N(B) ∪ top-N(C)
        //
        // **That holds only while every branch orders by the same total order as the
        // outer query — `created_at DESC, id DESC`.** It is a precondition, not a
        // property of the shape: a branch that later orders by anything else does not
        // fail loudly, it silently drops rows that belonged in the page. Anything added
        // here inherits that condition.
        //
        // Each branch then rides `event_timeline` — `(h, kind, created_at DESC, id)` —
        // in index order and stops, and the outer sort orders at most `3 * limit` rows
        // instead of the channel. The outbox branch is the exception and is fine: its
        // index is `(channel_id, created_at)` with no `event_id`, so SQLite walks it
        // backwards for `created_at DESC` and sorts only the `id` tiebreak, over at most
        // the pending sends. `USE TEMP B-TREE FOR LAST TERM OF ORDER BY` on that branch
        // is expected, not a regression.
        //
        // Measured on an 8,860-event log with 3,000 messages in the channel: 23.69 ms
        // unbounded against 1.04 ms bounded, with a byte-identical result set at the head
        // and at six cursor depths, pending sends landing inside the returned pages.
        // Independently reproduced at 27.14 ms against 0.96 ms. Harness and numbers in
        // `RESEARCH/TIMELINE_READ_COST.md`.
        //
        // An earlier comment here claimed the third branch existed because `kind IN (9,
        // 40099)` would cost the ordering that an equality on both leading index columns
        // preserved. That was wrong, and it claimed to have been verified. Both shapes
        // produce `USE TEMP B-TREE FOR ORDER BY`; the `LAST TERM OF ORDER BY` lines that
        // suggested otherwise appear three times in a *single* branch with no union at
        // all, because they belong to the edit subqueries' own ordering. The branch split
        // is kept because it is marginally faster and reads clearer, not because the
        // planner rewards it.
        let sql = """
        SELECT \(timelineColumns)
        FROM (
            SELECT * FROM (
                \(eventBranch(where: """
                    e.h = :channel AND e.kind = :kind AND \(page("e.created_at", "e.id"))
                      AND NOT EXISTS (
                            SELECT 1 FROM thread tx
                            WHERE tx.event_id = e.id AND tx.broadcast = 0
                          )
                    """))
                ORDER BY e.created_at DESC, e.id DESC
                LIMIT :limit
            )

            UNION ALL

            SELECT * FROM (
                \(eventBranch(where: """
                    e.h = :channel AND e.kind = :noticeKind
                      AND \(page("e.created_at", "e.id"))
                    """))
                ORDER BY e.created_at DESC, e.id DESC
                LIMIT :limit
            )

            UNION ALL

            SELECT * FROM (
                \(outboxBranch(where: """
                    o.channel_id = :channel AND o.parent_id IS NULL
                      AND \(page("o.created_at", "o.event_id"))
                    """))
                ORDER BY o.created_at DESC, o.event_id DESC
                LIMIT :limit
            )
        )
        ORDER BY created_at DESC, id DESC
        LIMIT :limit
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: [
            "channel": channel,
            "kind": EventKind.channelMessage.rawValue,
            "noticeKind": EventKind.systemMessage.rawValue,
            "hasCursor": cursor == nil ? 0 : 1,
            "ts": cursor?.createdAt ?? 0,
            "id": cursor?.id ?? "",
            "limit": limit,
        ])
        return makeRows(rows, selfPubkey: selfPubkey)
    }

    /// The thread query: the opener, its replies, and any pending replies.
    static func fetchThread(
        _ db: Database,
        root: String,
        selfPubkey: String? = nil
    ) throws -> [TimelineRow] {
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
        return makeRows(rows, selfPubkey: selfPubkey)
    }
}
