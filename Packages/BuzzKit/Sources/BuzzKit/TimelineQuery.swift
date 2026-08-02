import Foundation
import GRDB
import NostrCore

/// The pieces every timeline read is built from: the row shape as a column list, the
/// two branches it is unioned from, and the mapping back into ``TimelineRow``.
///
/// Split out of ``Timeline.swift`` so that file is the row shape and the reads that
/// return it. These are shared by three callers — the channel page, a thread, and the
/// by-id read in ``TimelineRows.swift`` — and a message assembled differently by any one
/// of them is a second definition of what a message is. Keeping them together also keeps
/// the two `UNION ALL` branches side by side, where a column added to one and forgotten
/// in the other is a positional mismatch at runtime rather than something you can see.
extension BuzzEventStore {
    /// One column list so the branches and every outer select cannot drift. Internal
    /// rather than private because `TimelineRows.swift` selects the same list.
    static let timelineColumns = """
    id, pubkey, created_at, kind, content, edited, deleted, rich,
    display_name, picture, parent_id, root_id, reply_count, last_reply_at,
    state, last_error, is_retryable, tags, edited_tags
    """

    /// The keyset paging predicate over a `(created_at, id)` cursor.
    ///
    /// The comparison and the id tiebreak both follow `direction`, so the predicate always
    /// matches the query's own `ORDER BY … created_at <dir>, id <dir>`. The two cannot be
    /// set independently: a predicate that disagreed with the order would keep serving rows
    /// it had already passed, which is the same silent failure the per-branch bound has —
    /// see ``fetchTimeline(_:channel:from:direction:limit:)``.
    ///
    /// `direction` is an enum, not caller text, so the interpolation carries no input.
    static func page(_ timestamp: String, _ identifier: String, _ direction: TimelineDirection) -> String {
        let compare = direction.comparison
        return """
        (:hasCursor = 0
         OR \(timestamp) \(compare) :ts
         OR (\(timestamp) = :ts AND \(identifier) \(compare) :id))
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
    /// removed stops advertising one. They are composed from this device's own replies
    /// and the relay's summary of the thread rather than counted purely locally — see
    /// ``replyCount``, which is where a message gets to advertise a thread whose
    /// replies this device has never held.
    ///
    /// `tags` and `edited_tags` come back as raw JSON rather than as anything decoded,
    /// because only ``makeRow(_:)`` knows which of the two to read. Nothing in SQL can
    /// pick between them without decoding the array it is choosing.
    static func eventBranch(where predicate: String) -> String {
        """
        SELECT e.id                AS id,
               e.pubkey            AS pubkey,
               e.created_at        AS created_at,
               e.kind              AS kind,
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
               \(replyCount)       AS reply_count,
               \(lastReplyAt)      AS last_reply_at,
               'sent'              AS state,
               NULL                AS last_error,
               0                   AS is_retryable,
               e.tags              AS tags,
               \(editedTags)       AS edited_tags
        FROM event e
        LEFT JOIN rich_content rc ON rc.target_id = e.id
        LEFT JOIN profile p ON p.pubkey = e.pubkey
        LEFT JOIN thread t ON t.event_id = e.id
        LEFT JOIN event_owner eo ON eo.event_id = e.id
        LEFT JOIN thread_summary tsum ON tsum.root_id = e.id
        LEFT JOIN thread_fetch tfetch ON tfetch.root_id = e.id
        WHERE \(predicate)
        """
    }

    // MARK: - The reply tally

    /// How many replies a message has, composed from the two sources that can know.
    ///
    /// # Why one source is not enough
    ///
    /// A channel page is `top_level: true` — that is what NIP-CW is *for* — so replies
    /// are never rows in it. Counting only what this device holds therefore reads zero
    /// across all of history on a cold launch, and a message advertised its thread only
    /// once you pressed it, the press being what fetched the replies that made its own
    /// CTA appear. The relay answers this without anybody fetching a reply: it ships a
    /// `kind:39005` beside every window page and pushes a freshly signed one to channel
    /// subscribers on every reply insert and every deletion.
    ///
    /// So the relay's tally is what makes the count independent of holding the replies
    /// — the property that keeps it constant as a thread grows without bound. But it
    /// cannot simply be trusted over the local one, because it has no recovery: the
    /// push is fan-out only and never stored, so one dropped by a full socket buffer
    /// (backgrounded, locked, flaky signal) is gone, and nothing re-fetches it — not
    /// reconnect, not reconcile, which only re-pages above its watermark.
    ///
    /// # The rule
    ///
    /// *The later word wins, and a fetch is a word.* Taking the larger of the two would
    /// be wrong in exactly one direction and permanently: a deletion the relay
    /// announced into a dropped frame would leave a withdrawn reply advertised forever,
    /// which is a worse lie than the one this fixes. So:
    ///
    /// - No summary, or one this client could not parse: the local count, unchanged
    ///   from before this existed.
    /// - A summary this device's fetch already accounted for (``Schema`` `thread_fetch`):
    ///   the local count. This device holds the whole thread and every later reply and
    ///   deletion reaches it as an ordinary stored event, so it is the fresher of the
    ///   two — and this is the branch that heals a stale-high summary the moment
    ///   somebody opens the thread.
    /// - Otherwise: the larger of the two. Neither is complete here — the summary may
    ///   predate replies that arrived live, and the local count is missing all of
    ///   history — and *for a count that has never been superseded by a fetch* the
    ///   larger is the one that has seen more.
    ///
    /// Both branches read a PK lookup on `thread_summary`/`thread_fetch`, and `CASE`
    /// evaluates only the branch it takes, so the local subquery still runs at most
    /// once per row.
    private static var replyCount: String {
        """
        CASE WHEN tsum.descendant_count IS NULL OR \(fetchAccountsForSummary)
             THEN \(localReplyCount)
             ELSE MAX(\(localReplyCount), tsum.descendant_count)
        END
        """
    }

    /// When a message's newest surviving reply arrived, composed by the same rule as
    /// ``replyCount`` so a row cannot show a count from one source beside a time from
    /// the other.
    ///
    /// `MAX` here is the two-argument scalar, which is NULL if either side is, hence
    /// the `COALESCE`: a device holding none of a thread's replies has no local time,
    /// and the summary's is then the only answer there is.
    ///
    /// It defers to `descendant_count` being present as well as its own field, so the
    /// count and the time can never be drawn from different sources — a summary the
    /// client could half-read would otherwise put a reply time on a message the same
    /// row says has no replies.
    private static var lastReplyAt: String {
        """
        CASE WHEN tsum.descendant_count IS NULL OR tsum.last_reply_at IS NULL
                  OR \(fetchAccountsForSummary)
             THEN \(localLastReplyAt)
             ELSE MAX(COALESCE(\(localLastReplyAt), 0), tsum.last_reply_at)
        END
        """
    }

    /// Whether the summary currently on file is the same one this device's last full
    /// fetch of the thread already took into account.
    ///
    /// An identity test, deliberately, and not a comparison of times: `updated_at` is
    /// the relay's clock and a fetch happens on the device's, so the timestamp form of
    /// this question is unanswerable without trusting two clocks to agree. `IS` rather
    /// than `=` because both sides are legitimately NULL — no fetch, or a fetch made
    /// when the relay had sent no summary yet — and `=` would yield NULL there, which
    /// `CASE WHEN` reads as false.
    ///
    /// Internal rather than private because the Threads screen composes its own reply
    /// count by the same rule (``threadActivity(selfPubkey:limit:)``), and two surfaces
    /// deciding *which tally is the later word* from two separately written predicates is
    /// how one of them silently stops agreeing with the other. A query using it must have
    /// `thread_summary` in scope as `tsum` and `thread_fetch` as `tfetch`.
    static let fetchAccountsForSummary = "tfetch.summary_event_id IS tsum.event_id"

    /// This device's own count of a message's surviving replies.
    ///
    /// Keyed on `root_id`, so it counts the whole subtree — which is why the summary
    /// field it composes with is `descendant_count` and not `reply_count`. The two
    /// agree in a flat thread and diverge the moment somebody replies to a reply.
    private static var localReplyCount: String {
        """
        (SELECT COUNT(*) FROM thread tc
          WHERE tc.root_id = e.id
            AND NOT \(deletionApplies(
                target: "tc.event_id",
                author: "tc.pubkey",
                owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = tc.event_id)"
            )))
        """
    }

    /// The newest surviving reply this device holds for a message, or NULL for none —
    /// so a thread whose only reply was removed stops advertising one.
    private static var localLastReplyAt: String {
        """
        (SELECT MAX(tl.created_at) FROM thread tl
          WHERE tl.root_id = e.id
            AND NOT \(deletionApplies(
                target: "tl.event_id",
                author: "tl.pubkey",
                owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = tl.event_id)"
            )))
        """
    }

    /// The tags of the same edit whose content the row is already showing, or NULL when
    /// no authorized edit applies.
    ///
    /// # Why an edit's tags travel with its content
    ///
    /// A kind-40003 edit carries a whole new event, tags included, and the reference
    /// clients overlay both halves together (`edit?.tags ?? event.tags` upstream). An
    /// edit that removed a picture, or added one, says so in its `imeta` tags and nowhere
    /// else — so reading the content from the edit and the attachments from the original
    /// would draw a message that no client ever published: the new words beside the old
    /// pictures.
    ///
    /// The `WHERE` and `ORDER BY` are character-for-character the ones the `edited`
    /// content subquery uses, which is the point: they must select the *same* edit, and
    /// two orderings that merely look equivalent would disagree the first time a message
    /// was edited twice within one second.
    ///
    /// The tags live on the edit's own logged event rather than in the `edit`
    /// projection — the projection stores what it needs to resolve authority, and this
    /// is the log answering a question about an event it already holds. A join that
    /// finds no such event yields NULL and the row falls back to the original's tags,
    /// which is the same answer as "no edit".
    private static let editedTags = """
    (SELECT ev.tags FROM edit ed
       JOIN event ev ON ev.id = ed.event_id
      WHERE ed.target_id = e.id
        AND (ed.pubkey = e.pubkey OR ed.pubkey = eo.owner_pubkey)
      ORDER BY ed.created_at DESC, ed.event_id DESC
      LIMIT 1)
    """

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
    ///
    /// Kept beside ``eventBranch(where:)`` rather than beside the reads that union
    /// them: `UNION ALL` matches columns by *position*, so a column added to one branch
    /// and forgotten in the other is a silent mis-read at runtime. Two files apart, that
    /// is a diff nobody sees; one screen apart, it is obvious.
    static func outboxBranch(where predicate: String) -> String {
        """
        SELECT o.event_id  AS id,
               o.pubkey    AS pubkey,
               o.created_at AS created_at,
               o.kind      AS kind,
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
               o.last_error AS last_error,
               o.is_retryable AS is_retryable,
               -- The queue denormalizes the signed event's tags for exactly this: a
               -- message still in flight shows its own attachments, not none of them.
               o.tags      AS tags,
               NULL        AS edited_tags
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

    static func makeRows(_ rows: [Row]) -> [TimelineRow] {
        rows.map(makeRow)
    }

    private static func makeRow(_ row: Row) -> TimelineRow {
        let edited: String? = row["edited"]
        // The edit's tags or the original's, never a mix: see ``editedTags``. An edit
        // that carries no `imeta` at all is an edit that removed the attachments, so an
        // empty result here is an answer and not a miss.
        let editedTags: String? = row["edited_tags"]
        // A relay notice and a message are the same row shape by design (see
        // ``fetchTimeline``), so the kind is what tells them apart. Decoded here, once
        // per read, for the same reason `media` is: the alternative is every render pass
        // re-parsing a JSON body whose answer never changes.
        let kind: Int? = row["kind"]
        let isNotice = kind == EventKind.systemMessage.rawValue
        let notice = isNotice ? SystemNotice.parse(row["content"] ?? "") : nil
        return TimelineRow(
            id: row["id"],
            pubkey: row["pubkey"],
            createdAt: row["created_at"],
            content: edited ?? row["content"],
            isEdited: edited != nil,
            isDeleted: row["deleted"] ?? false,
            richContent: row["rich"],
            delivery: Delivery(state: row["state"], lastError: row["last_error"]),
            failureIsRetryable: row["is_retryable"] ?? false,
            authorName: row["display_name"],
            authorPicture: row["picture"],
            parentID: row["parent_id"],
            rootID: row["root_id"],
            replyCount: row["reply_count"] ?? 0,
            lastReplyAt: row["last_reply_at"],
            media: MessageMedia.parse(tags: decodeTags(editedTags ?? row["tags"])),
            notice: notice,
            isNotice: isNotice
        )
    }
}
