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
    /// conversations entirely.
    ///
    /// **Four hundred was wrong, and the reasoning behind it was wrong twice over.** It was
    /// called "roughly a fortnight of a noisy workspace"; measured against the live relay it
    /// is about **26 hours** — this channel alone produced 149 qualifying events in 9 hours,
    /// and JT is in thirteen. Past the window conversations vanish with no indication, and
    /// the survivors' `eventCount` and `unreadCount` silently *undercount*, so "+8 more" and
    /// every chip badge would be wrong rather than merely truncated.
    ///
    /// It was also called "a bound on a read that re-runs per commit, so it does not grow
    /// with the log". That was false until `v11.activity-feed`: `EXPLAIN QUERY PLAN` showed
    /// `SCAN e` plus `USE TEMP B-TREE FOR ORDER BY`, so the whole log was evaluated and
    /// sorted *before* the limit applied — 125 ms over 50k events, 471 ms over 200k, on
    /// every committed transaction. With `event(kind, created_at DESC)` the planner walks
    /// newest-first and stops, which is what finally makes this number a bound rather than a
    /// decoration, and what makes raising it affordable.
    ///
    /// Three thousand is about a week of thirteen busy channels. Still finite, still a
    /// silent truncation at the edge — see ``BuzzEventStore/activityFeed(selfPubkey:limit:)``
    /// — but past the point where a normal day can reach it.
    static let scanLimit = 3000

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

    /// How much of a message body the read carries back.
    ///
    /// The scan reaches ``scanLimit`` events so that a busy thread cannot crowd out every
    /// other conversation — but all an event past a row's representative one ever
    /// contributes is `+1` to a count. Selecting whole bodies for all of them measured at
    /// ~1 MB of text crossing into Swift on **every commit**, against ~140 KB capped here,
    /// for nothing anyone can see: the row draws two tail-truncated lines of the newest
    /// event only.
    ///
    /// Two hundred characters rather than something tighter because the cut has to survive
    /// the widest phone at the smallest dynamic type, where two lines hold appreciably more
    /// than they do at the default. It is a *byte* cut in SQL rather than a grapheme-aware
    /// one, so it can split a multi-byte character at the boundary — harmless because SQLite
    /// returns the truncated bytes as text and SwiftUI renders the replacement character at
    /// worst, off the end of a string already being ellipsised.
    static let previewLength = 200

    /// Whether the event's author is an agent rather than a person.
    ///
    /// The same two facts ``DirectorySnapshot`` builds `isAgent` from
    /// (`Directory.swift:158`): a row in `agent_directory`, or the `bot` role on any
    /// channel membership. Asked in SQL rather than resolved in the view because it decides
    /// which *chip* a row appears under, and a filter that depends on a value the view has
    /// not loaded yet would flicker rows in and out as the roster arrives.
    ///
    /// # Why this exists at all
    ///
    /// The Agents chip was first built on the agent job kinds alone (43001–43006), which is
    /// what the relay's own feed SQL keys on. Checked against JT's live relay: **zero** such
    /// events exist, and every agent on it — Fizz, Bumble, Sentry — replies as an ordinary
    /// `kind:9` channel message. So the chip was empty and would have stayed empty. The
    /// relay's `agent_activity` feed bucket classifies by *author*, and returns exactly
    /// those kind-9 messages; this matches that. The kind list stays as well, so a real job
    /// event still classifies correctly if one ever arrives.
    private static let authorIsAgent = """
    (EXISTS (SELECT 1 FROM agent_directory ad WHERE ad.pubkey = e.pubkey)
     OR EXISTS (SELECT 1 FROM channel_member cm
                 WHERE cm.pubkey = e.pubkey AND LOWER(cm.role) = 'bot'))
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
    /// How far back the candidate scan reaches, in seconds. Thirty days.
    ///
    /// The index alone does not finish the job. `kind IN (…)` gives the planner one range
    /// per kind, and merging nine ranges into one `created_at` order still costs
    /// `USE TEMP B-TREE FOR ORDER BY` over *every* qualifying row before `LIMIT` applies —
    /// so without a floor the sort input is still the whole log. This bounds that input to a
    /// window instead, which is what makes ``scanLimit`` a real ceiling rather than a
    /// second-order one.
    ///
    /// Thirty days because this is an inbox: something that has sat unread for a month is
    /// not going to be actioned from a bell icon, and the conversation is still in its
    /// channel. Long enough that a quiet workspace's month-old mention survives.
    static let window: Int64 = 30 * 24 * 60 * 60

    /// The floor, relative to the newest qualifying event rather than to the wall clock.
    ///
    /// Self-relative on purpose. A `now()`-based floor would make this read depend on the
    /// clock, which makes it untestable against fixtures with fixed timestamps and — worse —
    /// would empty the screen on a device whose clock is wrong or which has been offline
    /// past the window. Anchoring to the newest thing the log actually holds means the
    /// window is always thirty days of *this workspace's* activity.
    private static let floor = """
    COALESCE((SELECT MAX(created_at) FROM event WHERE kind IN (\(kindList))), 0) - \(window)
    """

    static let candidateSQL = """
    WITH \(participantCTE)
    SELECT e.id             AS id,
           e.pubkey         AS pubkey,
           e.kind           AS kind,
           substr(e.content, 1, \(previewLength)) AS content,
           e.created_at     AS created_at,
           e.h              AS channel_id,
           c.name           AS channel_name,
           c.channel_type   AS channel_type,
           p.display_name   AS author_name,
           p.picture        AS author_picture,
           t.root_id        AS root_id,
           names_me.value IS NOT NULL AS names_me,
           \(authorIsAgent) AS author_is_agent,
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
      -- Bounds what the ORDER BY has to sort. See ``window``.
      AND e.created_at >= \(floor)
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
        let authorIsAgent: Bool
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
            authorIsAgent = row["author_is_agent"] ?? false
            isUnread = row["is_unread"] ?? false
        }

        /// Which categories this event lands in — plural, because one event genuinely is
        /// more than one thing, on three independent axes.
        ///
        /// **A kind that carries its own category wins outright**, and its `p` tag is not a
        /// mention. This is the subtle one, and it was worth checking against the relay
        /// rather than deciding: an approval request is *addressed* by its `p` tag — that is
        /// how it reaches the person who must approve it, so **every** approval and **every**
        /// job report carries one. Counting those as mentions would file all of them under
        /// Mentions, which is the one chip JT actually asked for, and drown it.
        ///
        /// The relay draws exactly this line and it is the parity target: `query_mentions`
        /// and `query_needs_action` join the *same* `event_mentions` p-tag table, and the
        /// mention query's kind list deliberately excludes 46010 and 40007
        /// (`crates/buzz-db/src/feed.rs:106` vs `:191`). So a p-tag on those kinds is
        /// addressing on both clients.
        ///
        /// A review flagged the early return as a bug — an approval naming you having
        /// `matches(.mention) == false` while three doc comments claimed otherwise. The
        /// inconsistency was real; the claims were what was wrong, not this. They are fixed.
        ///
        /// For a plain message the `p` tag *is* social, and there the axes are genuinely
        /// independent: an agent that names you gives `[.mention, .agentActivity]`, so the
        /// row reads as a **Mention** and still answers the Agents chip. Collapsing that pair
        /// is what left Agents permanently empty in the first cut.
        var categories: Set<ActivityCategory> {
            if let byKind = ActivityKinds.category(forKind: event.kind) { return [byKind] }
            var present: Set<ActivityCategory> = [namesMe ? .mention : .activity]
            if authorIsAgent { present.insert(.agentActivity) }
            return present
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
            categories[key, default: []].formUnion(candidate.categories)
        }

        return order.prefix(limit).compactMap { key -> ActivityEntry? in
            guard let candidate = latest[key] else { return nil }
            // Loudest first. The row wears the first one and matches any of them, so an
            // agent that names you is filed under Mention and still appears under Agents —
            // the behaviour desktop gets from carrying a `categories` array on every inbox
            // item rather than a single category.
            let present = (categories[key] ?? candidate.categories)
                .sorted { $0.priority < $1.priority }
            return ActivityEntry(
                id: key,
                category: present.first ?? .activity,
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
