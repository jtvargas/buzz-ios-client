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
    state, last_error, tags, edited_tags
    """

    /// The keyset paging predicate over a `(created_at, id)` cursor. Descending id
    /// in the tiebreak so it matches the query's `ORDER BY … id DESC`.
    static func page(_ timestamp: String, _ identifier: String) -> String {
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
               NULL                AS last_error,
               e.tags              AS tags,
               \(editedTags)       AS edited_tags
        FROM event e
        LEFT JOIN rich_content rc ON rc.target_id = e.id
        LEFT JOIN profile p ON p.pubkey = e.pubkey
        LEFT JOIN thread t ON t.event_id = e.id
        LEFT JOIN event_owner eo ON eo.event_id = e.id
        WHERE \(predicate)
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
