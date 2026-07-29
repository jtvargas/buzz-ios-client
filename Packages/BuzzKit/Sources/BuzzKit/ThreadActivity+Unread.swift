import Foundation
import GRDB
import NostrCore

/// The sidebar's unread-threads read, split out of ``ThreadActivity`` so that file stays
/// the shared vocabulary — the row types, the frontier, and the two ways of reaching a
/// surviving reply — and this one is the query that consumes them.
///
/// Both CTEs it uses live next to their unnarrowed sibling rather than here, because a
/// near-identical CTE a file away from the one it must agree with is how the two stop
/// agreeing.
extension BuzzEventStore {
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
    ///
    /// # Two passes, and why the first one is allowed to be wrong
    ///
    /// This runs on the sidebar's per-commit path beside ``fetchChannelList(_:selfPubkey:)``.
    /// It used to resolve every surviving reply in the store — the deletion predicate, the
    /// root join and the frontier join, once per reply — and then throw away every thread
    /// whose count came out zero. ``threadCandidateCTE`` decides which threads those are
    /// first, using only the two predicates that need no joins, and the expensive pass then
    /// runs over what is left.
    ///
    /// The first pass is a *superset* by construction, which is what makes it safe: it omits
    /// the deletion check, so it can admit a thread whose only new reply turns out to be
    /// deleted, and `HAVING new_count > 0` drops it exactly as before. It cannot omit a
    /// thread, because a thread with a new reply has a reply meeting both of its conditions.
    ///
    /// **The shape is unchanged and still walks every reply** — this is a constant-factor
    /// win, not a smaller one. It is worth an extra pass because there is no index that
    /// would do better: `thread_root` is `(root_id, created_at, event_id)`, and a
    /// `created_at` index is refused by the planner and loses to the covering scan when
    /// forced, because the candidate pass needs `root_id` grouped and that ordering is the
    /// thing such an index throws away. Measured at roughly **−40%**, holding in both the
    /// every-channel-read and the never-read states; absolutes and the plan output are in
    /// `RESEARCH/SIDEBAR_READ_COST.md`, taken on a loaded machine and stated as ratios for
    /// that reason.
    private static let unreadThreadsSQL = """
        WITH \(threadFrontierCTE),
        \(threadCandidateCTE),
        \(threadRepliesForCandidatesCTE)
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
