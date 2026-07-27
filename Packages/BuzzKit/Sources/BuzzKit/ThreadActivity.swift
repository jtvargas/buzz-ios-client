import Foundation
import GRDB
import NostrCore

/// One thread as a "what has been happening" list needs it: the message that opened it,
/// the newest reply to it, and how much sits between them.
///
/// Both messages are ordinary ``TimelineRow``s, resolved through the same read the
/// timeline and a thread use — so the text here is the text there, with the newest
/// authorized edit applied and a deleted message rendered as one rather than silently
/// showing its original content.
public struct ThreadActivity: Sendable, Hashable, Identifiable {
    /// The thread's root event id, which is also its identity in any list.
    public let rootID: String
    /// The channel the thread lives in, for opening it.
    public let channelID: String
    /// The message that started the thread.
    public let opener: TimelineRow
    /// Its newest surviving reply. Never absent: a root with no surviving replies is not
    /// a thread and does not appear in this read at all.
    public let latestReply: TimelineRow
    /// The `created_at` of the newest surviving reply somebody **else** wrote, or `nil` when
    /// every reply in the thread is the reader's own.
    ///
    /// What a device-local "I have seen this thread" mark is *compared against* — and the
    /// reason that is not ``latestReply``'s timestamp. A mark is *set* from the newest reply
    /// the reader had on screen, which is very often one they wrote themselves; comparing the
    /// two lets the reader's own words resurface the thread. Reply from the phone and the
    /// mark moves with the reply, so nothing shows. Reply from the desktop to a thread
    /// already read on the phone and only the timestamp moves — past a mark on a device that
    /// never saw it — and the thread comes back as new on the strength of something the
    /// reader said. Set from and compared against are one field apart and one bug apart:
    /// keep them apart.
    ///
    /// Optional rather than `0`, because "nobody else has said anything here" is a state this
    /// read really does return — the Threads screen lists recent activity, not only unread
    /// activity, so a thread the reader alone has replied in still appears — and `0` would
    /// answer it only by accident, comparing as "seen" because marks happen never to be zero.
    /// Nothing anybody else said is nothing to be behind on, and `nil` says so outright.
    public let latestReplyByOthersAt: Int64?
    /// Every surviving reply, the newest one included.
    public let replyCount: Int
    /// How many of those replies are newer than the channel's read frontier and were
    /// written by somebody else — the number behind the Threads card.
    public let newReplyCount: Int

    public var id: String { rootID }

    public init(
        rootID: String,
        channelID: String,
        opener: TimelineRow,
        latestReply: TimelineRow,
        latestReplyByOthersAt: Int64?,
        replyCount: Int,
        newReplyCount: Int
    ) {
        self.rootID = rootID
        self.channelID = channelID
        self.opener = opener
        self.latestReply = latestReply
        self.latestReplyByOthersAt = latestReplyByOthersAt
        self.replyCount = replyCount
        self.newReplyCount = newReplyCount
    }

    /// The replies between the opener and the newest one — what a row summarises as
    /// "3 more replies" rather than drawing.
    ///
    /// Zero for a thread with a single reply, where the opener and that reply are the
    /// whole thread and there is nothing being hidden to admit to.
    public var intermediateReplyCount: Int { max(0, replyCount - 1) }

    public var hasNewReplies: Bool { newReplyCount > 0 }
}

/// One thread holding replies the reader has not seen: which thread, how many, and how
/// recent the newest reply in it is.
///
/// Deliberately carries no message content. It is read on every committed transaction to
/// draw a single number on the home screen, so it stays ids and integers — the openers and
/// replies behind them are resolved only by ``BuzzEventStore/threadActivity(selfPubkey:limit:)``,
/// which runs while the Threads screen is actually open.
public struct UnreadThread: Sendable, Hashable, Identifiable {
    /// The thread's root event id.
    public let rootID: String
    /// Replies newer than the channel's read frontier, written by somebody else.
    public let newReplyCount: Int
    /// The newest surviving reply's `created_at`, the reader's own included — what this list
    /// is ordered by, and the *shape* a device-local mark takes, since a mark is set from the
    /// newest reply the reader had on screen and that may well be their own.
    ///
    /// Never what a mark is compared against: see ``latestReplyByOthersAt``.
    public let latestReplyAt: Int64
    /// The `created_at` of the newest surviving reply somebody **else** wrote — the value a
    /// device-local "I have seen this thread" mark *is* compared against, so that a reply of
    /// the reader's own arriving from another device cannot resurface a thread they have
    /// already read here. ``ThreadActivity/latestReplyByOthersAt`` carries the argument in
    /// full.
    ///
    /// Not optional, unlike there, and not by oversight: a thread reaches this read only by
    /// holding a reply that is both newer than its channel's frontier and somebody else's
    /// (`HAVING new_count > 0`), so a reply by somebody else always exists to take the
    /// maximum of. The absent case is unreachable here, so it is unrepresentable here.
    public let latestReplyByOthersAt: Int64

    public var id: String { rootID }

    public init(rootID: String, newReplyCount: Int, latestReplyAt: Int64, latestReplyByOthersAt: Int64) {
        self.rootID = rootID
        self.newReplyCount = newReplyCount
        self.latestReplyAt = latestReplyAt
        self.latestReplyByOthersAt = latestReplyByOthersAt
    }
}

public extension BuzzEventStore {
    /// Threads with replies, most recently active first.
    ///
    /// # What "new" means, and what it cannot mean
    ///
    /// A reply is new when it is newer than its **channel's** read frontier and somebody
    /// else wrote it. There is no per-thread read state to consult — NIP-RS keys its
    /// contexts by channel — so opening the channel and reading to the bottom also clears
    /// its threads. That is a real limitation rather than an approximation of something
    /// finer: the alternative would be a second, invented read frontier that no other
    /// Buzz client would ever see or advance.
    ///
    /// Synchronous and `nonisolated`, so it runs on the concurrent reader and a
    /// `ValueObservation` can track the tables behind it.
    ///
    /// - Parameters:
    ///   - selfPubkey: the local identity, so your own replies are not "new" to you.
    ///     `nil` counts every author, the same keyless fallback the unread count takes.
    ///   - limit: how many threads to return. No default: the number belongs to the
    ///     surface that decides how far its list reaches.
    nonisolated func threadActivity(selfPubkey: String?, limit: Int) throws -> [ThreadActivity] {
        guard limit > 0 else { return [] }
        return try reader.read { db in
            try Self.fetchThreadActivity(db, selfPubkey: selfPubkey, limit: limit)
        }
    }

    /// The threads holding replies the reader has not seen, newest activity first — what
    /// the Threads card counts.
    ///
    /// A list of roots rather than a bare number, because the number the card shows is not
    /// this list's length: a thread the reader has already opened on this device is struck
    /// off by ``ThreadReadMarks``, whose marks live in `UserDefaults` and so cannot be
    /// joined here. Handing back the roots and the timestamps that subtraction turns on is
    /// what lets it happen in the one place that knows about it, over ids and integers
    /// rather than over message content.
    ///
    /// Its own query rather than a tally over ``threadActivity(selfPubkey:limit:)``,
    /// because this one runs on the sidebar's per-commit path while that one only runs
    /// while the Threads screen is open — and this one touches no message content at all.
    nonisolated func unreadThreads(selfPubkey: String?) throws -> [UnreadThread] {
        try reader.read { db in try Self.fetchUnreadThreads(db, selfPubkey: selfPubkey) }
    }
}

extension BuzzEventStore {
    /// The per-channel read frontier, `MAX(read_at)` across every device's slot — the
    /// same grow-only merge the channel list's unread count applies, written once here so
    /// the two cannot disagree about what "read" means.
    static let threadFrontierCTE = """
    frontier AS (
        SELECT context_id AS channel_id, MAX(read_at) AS read_at
        FROM read_state
        GROUP BY context_id
    )
    """

    /// Surviving replies, joined to the frontier of the channel their root lives in.
    ///
    /// The channel comes from the **root's** `h` rather than from `thread.channel_id`,
    /// which is nullable: a reply projected before its scope was known would otherwise
    /// join no frontier and count as new forever.
    static let threadRepliesCTE = """
    reply AS (
        SELECT t.root_id    AS root_id,
               t.event_id   AS event_id,
               t.created_at AS created_at,
               t.pubkey     AS pubkey,
               COALESCE(f.read_at, 0) AS read_at
        FROM thread t
        JOIN event root ON root.id = t.root_id
        LEFT JOIN frontier f ON f.channel_id = root.h
        LEFT JOIN event_owner teo ON teo.event_id = t.event_id
        WHERE NOT \(deletionApplies(target: "t.event_id", author: "t.pubkey", owner: "teo.owner_pubkey"))
    )
    """

    /// Two reads rather than one wide join. ``threadSummaries(_:selfPubkey:limit:)``
    /// decides *which* threads and in what order, touching only ids, timestamps and keys;
    /// this one resolves the two messages per thread through ``fetchRows(_:ids:)`` — the
    /// timeline's own row read, so edits, deletions, rich content and author names are
    /// applied here exactly as they are in the thread a row opens.
    static func fetchThreadActivity(
        _ db: Database,
        selfPubkey: String?,
        limit: Int
    ) throws -> [ThreadActivity] {
        let summaries = try threadSummaries(db, selfPubkey: selfPubkey, limit: limit)
        guard !summaries.isEmpty else { return [] }

        let ids = summaries.flatMap { [$0["root_id"] as String, $0["latest_reply_id"] as String] }
        let rows = try fetchRows(db, ids: Array(Set(ids)))
        let byID = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        return summaries.compactMap { summary in
            let rootID: String = summary["root_id"]
            let replyID: String = summary["latest_reply_id"]
            // A summary whose messages the row read cannot resolve is dropped rather than
            // rendered half-empty. It should not happen — both ids came from `event` in
            // the same transaction — so silence here is correct, not a swallowed error.
            guard let opener = byID[rootID], let reply = byID[replyID] else { return nil }
            // Bound to its own `let` so the column's NULL — every reply in the thread is the
            // reader's own — arrives as `nil` rather than being coalesced to a `0` that would
            // read as a timestamp nobody can be behind.
            let byOthersAt: Int64? = summary["latest_other_reply_at"]
            return ThreadActivity(
                rootID: rootID,
                channelID: summary["channel_id"],
                opener: opener,
                latestReply: reply,
                latestReplyByOthersAt: byOthersAt,
                replyCount: summary["reply_count"] ?? 0,
                newReplyCount: summary["new_count"] ?? 0
            )
        }
    }

    /// Which threads have been active, in what order, and how much is in them — ids and
    /// numbers only, no message content.
    private static func threadSummaries(
        _ db: Database,
        selfPubkey: String?,
        limit: Int
    ) throws -> [Row] {
        try Row.fetchAll(db, sql: threadSummariesSQL, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
            "limit": limit,
        ])
    }

    /// The query behind ``threadSummaries(_:selfPubkey:limit:)``, hoisted out of it for the
    /// same reason its sibling below is: a function whose body is one string literal reads
    /// better as a named string and a two-line call.
    private static let threadSummariesSQL = """
        WITH \(threadFrontierCTE),
        \(threadRepliesCTE),
        tally AS (
            SELECT r.root_id AS root_id,
                   COUNT(*)  AS reply_count,
                   -- The newest reply by somebody else, over *every* surviving reply and not
                   -- only the new ones: a device-local mark can sit anywhere the reader has
                   -- read to, including past this channel's frontier, so the value it is
                   -- compared against has to be the last thing anybody else said full stop.
                   -- NULL when they are all the reader's own, which is a thread this read
                   -- still lists — it shows recent activity, not only unread activity.
                   MAX(CASE
                         WHEN :selfPubkey IS NULL OR r.pubkey <> :selfPubkey
                         THEN r.created_at
                       END) AS latest_other_reply_at,
                   SUM(CASE
                         WHEN r.created_at > r.read_at
                          AND (:selfPubkey IS NULL OR r.pubkey <> :selfPubkey)
                         THEN 1 ELSE 0
                       END) AS new_count
            FROM reply r
            GROUP BY r.root_id
        )
        SELECT tally.root_id     AS root_id,
               root.h            AS channel_id,
               newest.event_id   AS latest_reply_id,
               newest.created_at AS latest_reply_at,
               tally.latest_other_reply_at AS latest_other_reply_at,
               tally.reply_count AS reply_count,
               tally.new_count   AS new_count
        FROM tally
        JOIN event root ON root.id = tally.root_id
        LEFT JOIN event_owner reo ON reo.event_id = root.id
        -- The newest surviving reply on the same `(created_at, id)` keyset the timeline
        -- pages on, so "newest" means one thing across the app.
        JOIN reply newest ON newest.root_id = tally.root_id
         AND NOT EXISTS (
               SELECT 1 FROM reply r2
                WHERE r2.root_id = newest.root_id
                  AND (r2.created_at > newest.created_at
                       OR (r2.created_at = newest.created_at AND r2.event_id > newest.event_id))
             )
        WHERE root.kind = :kind
          AND root.h IS NOT NULL
          -- A thread whose opener was deleted is not one anybody can usefully be sent to.
          AND NOT \(deletionApplies(target: "root.id", author: "root.pubkey", owner: "reo.owner_pubkey"))
        ORDER BY latest_reply_at DESC, latest_reply_id DESC
        LIMIT :limit
        """

    /// The unread roots, aggregated per thread.
    ///
    /// Two maxima over the same grouped pass, and they are not interchangeable.
    /// `latest_reply_at` spans every surviving reply, the reader's own included: it orders
    /// the list and it is the shape a device-local mark takes, since a mark is set from the
    /// newest reply that was on screen. `latest_other_reply_at` spans only replies somebody
    /// else wrote, and it is the one a mark is *compared* against — otherwise a reply the
    /// reader sent from another device outruns the mark their phone set and the thread comes
    /// back as unread on the strength of their own message.
    ///
    /// The conditional maximum is unrestricted by the frontier while `new_count` is not, and
    /// under `HAVING new_count > 0` the two agree anyway: any reply newer than the newest
    /// *new* foreign one is itself past the frontier and therefore also new. The unrestricted
    /// form is written because it is the honest statement of "the last thing somebody else
    /// said", and it survives a future caller that drops the `HAVING`.
    static func fetchUnreadThreads(_ db: Database, selfPubkey: String?) throws -> [UnreadThread] {
        try Row.fetchAll(db, sql: unreadThreadsSQL, arguments: [
            "kind": EventKind.channelMessage.rawValue,
            "selfPubkey": selfPubkey,
        ]).map { row in
            UnreadThread(
                rootID: row["root_id"],
                newReplyCount: row["new_count"] ?? 0,
                latestReplyAt: row["latest_reply_at"] ?? 0,
                // Unreachable: `HAVING new_count > 0` guarantees a reply by somebody else,
                // so the conditional maximum has a row to take. `0` rather than a trap
                // because the harmless direction to be wrong in, if the impossible happens,
                // is a thread that stays struck off — not one that cannot be struck off.
                latestReplyByOthersAt: row["latest_other_reply_at"] ?? 0
            )
        }
    }

    /// The query behind ``fetchUnreadThreads(_:selfPubkey:)``, hoisted out of it so the
    /// function reads as the mapping it now is.
    private static let unreadThreadsSQL = """
        WITH \(threadFrontierCTE),
        \(threadRepliesCTE)
        SELECT r.root_id           AS root_id,
               MAX(r.created_at)   AS latest_reply_at,
               MAX(CASE
                     WHEN :selfPubkey IS NULL OR r.pubkey <> :selfPubkey
                     THEN r.created_at
                   END) AS latest_other_reply_at,
               SUM(CASE
                     WHEN r.created_at > r.read_at
                      AND (:selfPubkey IS NULL OR r.pubkey <> :selfPubkey)
                     THEN 1 ELSE 0
                   END) AS new_count
        FROM reply r
        JOIN event root2 ON root2.id = r.root_id
        LEFT JOIN event_owner reo ON reo.event_id = root2.id
        WHERE root2.kind = :kind
          AND root2.h IS NOT NULL
          AND NOT \(deletionApplies(target: "root2.id", author: "root2.pubkey", owner: "reo.owner_pubkey"))
        GROUP BY r.root_id
        HAVING new_count > 0
        ORDER BY latest_reply_at DESC, root_id DESC
        """
}
