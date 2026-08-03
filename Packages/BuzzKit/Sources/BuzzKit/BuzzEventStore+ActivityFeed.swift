import Foundation
import GRDB
import NostrCore

public extension BuzzEventStore {
    /// Everything addressed to you, collapsed to one row per conversation, newest first.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the actor, and
    /// so `ValueObservation` can track the tables it reads — the same discipline as
    /// ``channelList(selfPubkey:)`` and ``threadActivity(selfPubkey:limit:)``. That is what
    /// makes this screen live: a mention arriving over the standing channel subscription
    /// commits, the observation fires, and the row appears without a poll or a pull.
    ///
    /// # Why this is computed here and not asked of the relay
    ///
    /// The relay does have a categorised feed (`crates/buzz-db/src/feed.rs`, reachable as
    /// `feed_types` on a bridge filter) and both other clients use it. Hive does not, for
    /// three reasons that all point the same way: every event this screen can show is
    /// already in the log — it arrived over the channel subscriptions that draw the
    /// sidebar — so a second fetch would be paying twice for the same bytes; a relay feed
    /// is a snapshot and would sit stale between refreshes where this updates on commit;
    /// and unread state is local, so a relay-side feed could not tell you which of these
    /// you have already seen.
    ///
    /// - Parameters:
    ///   - selfPubkey: the local identity. `nil` yields an empty feed rather than a
    ///     stranger's — "addressed to you" has no meaning without a you.
    ///   - limit: how many *conversations* to return. Not how many events are read; see
    ///     ``ActivityFeedRead/scanLimit``.
    nonisolated func activityFeed(selfPubkey: String?, limit: Int) throws -> [ActivityEntry] {
        guard let selfPubkey, !selfPubkey.isEmpty, limit > 0 else { return [] }
        let identity = selfPubkey.lowercased()
        return try reader.read { db in
            try ActivityFeedRead.fetch(db, selfPubkey: identity, limit: limit)
        }
    }
}

/// The activity read: one SQL pass that selects and classifies candidate events, then a
/// Swift pass that collapses them into conversations.
///
/// The split is deliberate. Selecting *which* events qualify is a question about indexes
/// and belongs in SQL; collapsing them into rows is a question about presentation, and
/// desktop answers it in TypeScript for the same reason
/// (`desktop/src/features/home/lib/inbox.ts`, `buildInboxItems`). Doing the grouping in
/// SQL would need window functions over a set already bounded to a few hundred rows, and
/// would put the rule that decides what a row *says* somewhere no test can reach it
/// without a database.
enum ActivityFeedRead {
    /// How many events are examined before grouping.
    ///
    /// Larger than the row limit on purpose, and this is the number that matters: a busy
    /// thread can contribute forty events to one row, so a scan bounded at the row count
    /// would return forty rows' worth of one conversation and drop the other thirty-nine
    /// conversations entirely. Four hundred is roughly a fortnight of a noisy workspace,
    /// and it is a bound on a read that re-runs per commit, so it does not grow with the
    /// log.
    static let scanLimit = 400

    /// Roots the reader has replied in — the same definition
    /// ``BuzzEventStore/threadActivity(selfPubkey:limit:)`` uses, so "a thread I am in"
    /// means one thing across the app. Copied in shape rather than imported because that
    /// one is `private` to the thread read; if a third caller appears, hoist it.
    private static let participantCTE = """
    participant AS (
        SELECT DISTINCT t.root_id AS root_id
        FROM thread t
        LEFT JOIN event_owner teo ON teo.event_id = t.event_id
        WHERE t.pubkey = :selfPubkey
          AND NOT \(BuzzEventStore.deletionApplies(
              target: "t.event_id", author: "t.pubkey", owner: "teo.owner_pubkey"
          ))
    )
    """

    /// One channel's effective read frontier — `MAX(read_at)` across every device's NIP-RS
    /// slot, identical to ``ChannelList``'s. `MAX` over no rows is NULL and falls to 0, so
    /// a channel nothing has ever marked read counts as entirely unread, which is the
    /// conservative default: telling someone they have nothing new when the state is
    /// unknown is the failure that loses a message.
    private static let channelFrontier = """
    COALESCE((SELECT MAX(read_at) FROM read_state WHERE context_id = e.h), 0)
    """

    /// The candidate query: every event that qualifies for the feed, classified, newest
    /// first.
    ///
    /// # What qualifies
    ///
    /// Four disjuncts, in the order a reader would name them:
    ///
    /// 1. **It names you.** A `p` tag carrying the local identity. This is what makes a
    ///    mention, an approval request, and an agent job report reach you, and it is the
    ///    only route for the non-message kinds — matching the relay, whose needs-action and
    ///    job queries are both `p`-scoped (`crates/buzz-db/src/feed.rs:191`, `:265`).
    /// 2. **It is a direct message.** A DM did not need to `@` you; the channel is the
    ///    address. Kept as a channel-type test rather than a `p` tag because a DM's own
    ///    messages carry no `p` tag naming the recipient — only its creation event does.
    /// 3. **It is a reply under a message of yours.**
    /// 4. **It is a reply in a thread you have spoken in.**
    ///
    /// # Where this deliberately narrows the relay
    ///
    /// The relay's `query_feed_activity` takes no pubkey at all — its "activity" is *every*
    /// recent event in *every* accessible channel (`crates/buzz-db/src/feed.rs:265`), which
    /// on desktop sits in a three-pane window next to the channel list. On a phone that is
    /// a second copy of the sidebar wearing a bell, and it is precisely the noise that
    /// makes an activity screen unreadable. Disjuncts 2–4 are the narrowing: activity here
    /// means *conversations you are in*, not the workspace firehose. Stated loudly because
    /// it is a product decision, not an implementation detail — it is the one thing on this
    /// screen that is not parity.
    ///
    /// `COLLATE NOCASE` on the tag value and binary `=` on `event.pubkey`, for the reasons
    /// ``ChannelList/channelListSQL`` sets out at length: a tag value is a raw string
    /// written by whichever client sent the message and never decoded, while a stored
    /// pubkey went through NIP-01's strictly-lowercase hex decode. Missing a mention
    /// because another client upper-cased a key is the worse failure; paying `NOCASE` on
    /// `event.pubkey` is the difference between 2 ms and 63 ms.
    static let candidateSQL = """
    WITH \(participantCTE)
    SELECT e.id             AS id,
           e.pubkey         AS pubkey,
           e.kind           AS kind,
           e.content        AS content,
           e.created_at     AS created_at,
           e.h              AS channel_id,
           c.name           AS channel_name,
           c.channel_type   AS channel_type,
           p.display_name   AS author_name,
           p.picture        AS author_picture,
           t.root_id        AS root_id,
           names_me.value IS NOT NULL AS names_me,
           e.created_at > \(channelFrontier) AS is_unread
    FROM event e
    LEFT JOIN thread t        ON t.event_id = e.id
    LEFT JOIN event rootev    ON rootev.id = t.root_id
    LEFT JOIN event_owner eo  ON eo.event_id = e.id
    LEFT JOIN channel c       ON c.id = e.h
    LEFT JOIN profile p       ON p.pubkey = e.pubkey
    LEFT JOIN channel_access ca
           ON ca.channel_id = e.h AND ca.identity_pubkey = :selfPubkey
    LEFT JOIN event_tag names_me
           ON names_me.event_id = e.id
          AND names_me.name = 'p'
          AND names_me.value = :selfPubkey COLLATE NOCASE
    WHERE e.kind IN (\(kindList))
      -- Your own messages are not news to you. Binary `=`, so the `event_author` index
      -- serves it; see ``RecentMentions``.
      AND e.pubkey <> :selfPubkey
      -- A channel you have left, been removed from, or archived is not activity. An event
      -- with no `h` at all is kept: it is channel-less by nature, not orphaned.
      AND (e.h IS NULL OR (ca.state = 'active' AND COALESCE(c.is_archived, 0) = 0))
      AND NOT \(BuzzEventStore.deletionApplies(
          target: "e.id", author: "e.pubkey", owner: "eo.owner_pubkey"
      ))
      AND (
            names_me.value IS NOT NULL
         OR c.channel_type = 'dm'
         OR rootev.pubkey = :selfPubkey
         OR EXISTS (SELECT 1 FROM participant WHERE participant.root_id = t.root_id)
      )
    ORDER BY e.created_at DESC, e.id DESC
    LIMIT :scan
    """

    /// The kinds the `IN` clause tests, sorted so the SQL string is stable across runs —
    /// a `Set`'s iteration order is not, and an unstable query string defeats SQLite's
    /// prepared-statement cache and makes two identical reads look different in a trace.
    private static var kindList: String {
        ActivityKinds.all.sorted().map(String.init).joined(separator: ", ")
    }

    static func fetch(_ db: Database, selfPubkey: String, limit: Int) throws -> [ActivityEntry] {
        let rows = try Row.fetchAll(db, sql: candidateSQL, arguments: [
            "selfPubkey": selfPubkey,
            "scan": scanLimit,
        ])
        return group(rows.map(Candidate.init), limit: limit)
    }

    /// One candidate event, as the SQL hands it over.
    struct Candidate {
        let event: ActivityEvent
        let channelID: String?
        let channelName: String
        let isDirectMessage: Bool
        let rootID: String?
        let namesMe: Bool
        let isUnread: Bool

        init(_ row: Row) {
            let pubkey: String = row["pubkey"]
            let name: String? = row["author_name"]
            event = ActivityEvent(
                id: row["id"],
                pubkey: pubkey,
                // Mirrors ``ChannelList``'s fallback: a present-but-empty profile name is
                // not a name, so it falls back to the key rather than rendering a blank
                // row. Shortening it for display is the view's business.
                authorName: (name?.isEmpty == false) ? name! : pubkey,
                authorPicture: row["author_picture"],
                kind: row["kind"] ?? 0,
                content: row["content"] ?? "",
                createdAt: row["created_at"] ?? 0
            )
            channelID = row["channel_id"]
            channelName = row["channel_name"] ?? ""
            isDirectMessage = (row["channel_type"] as String?) == "dm"
            rootID = row["root_id"]
            namesMe = row["names_me"] ?? false
            isUnread = row["is_unread"] ?? false
        }

        /// Which category this event lands in.
        ///
        /// Kind decides first: an approval request or a job report is what it is wherever
        /// it arrived. Only a plain message falls through to "does it name me", and only
        /// then to activity — which by the `WHERE` clause above means it reached the feed
        /// through the DM or thread-participation route.
        var category: ActivityCategory {
            ActivityKinds.category(forKind: event.kind) ?? (namesMe ? .mention : .activity)
        }

        /// The conversation this event belongs to.
        ///
        /// A thread's root, a DM's channel, or — for a top-level channel message — the
        /// event itself. Two separate top-level messages that both name you *are* two
        /// things to deal with and stay two rows; nine replies inside one thread are one.
        ///
        /// The DM case keys on the channel rather than the root so a direct conversation
        /// stays one row however its messages are threaded, which is how every messaging
        /// app on the phone behaves and how the Flutter client groups DMs
        /// (`mobile/lib/features/activity/inbox_item.dart`).
        var conversationID: String {
            if let rootID { return rootID }
            if isDirectMessage, let channelID { return channelID }
            return event.id
        }
    }

    /// Collapse candidates into conversations, newest first.
    ///
    /// Input must be newest-first — the SQL guarantees it — because the first candidate
    /// seen for a conversation is taken as its representative event. Doing it that way
    /// rather than by re-sorting keeps this a single pass and keeps the tiebreak identical
    /// to the SQL's (`created_at DESC, id DESC`), which matters for two events written in
    /// the same second.
    ///
    /// Newest-first as the representative is where this departs from desktop, which takes
    /// the oldest *unread* one instead. The argument is on ``ActivityEntry/latest``.
    static func group(_ candidates: [Candidate], limit: Int) -> [ActivityEntry] {
        var order: [String] = []
        var latest: [String: Candidate] = [:]
        var counts: [String: Int] = [:]
        var unread: [String: Int] = [:]
        var categories: [String: Set<ActivityCategory>] = [:]

        for candidate in candidates {
            let key = candidate.conversationID
            if latest[key] == nil {
                latest[key] = candidate
                order.append(key)
            }
            counts[key, default: 0] += 1
            if candidate.isUnread { unread[key, default: 0] += 1 }
            categories[key, default: []].insert(candidate.category)
        }

        return order.prefix(limit).compactMap { key -> ActivityEntry? in
            guard let candidate = latest[key] else { return nil }
            // Loudest first. The row wears the first one and matches any of them, so an
            // approval that also names you is filed under Action and still appears under
            // Mentions — the behaviour desktop gets from carrying a `categories` array on
            // every inbox item rather than a single category.
            let present = (categories[key] ?? [candidate.category])
                .sorted { $0.priority < $1.priority }
            return ActivityEntry(
                id: key,
                category: present.first ?? candidate.category,
                categories: present,
                channelID: candidate.channelID,
                channelName: candidate.channelName,
                isDirectMessage: candidate.isDirectMessage,
                latest: candidate.event,
                eventCount: counts[key] ?? 1,
                unreadCount: unread[key] ?? 0,
                rootID: candidate.rootID
            )
        }
    }
}
