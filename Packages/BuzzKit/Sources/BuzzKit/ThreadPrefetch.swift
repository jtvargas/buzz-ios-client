import Foundation
import GRDB
import NostrCore

/// A thread the relay knows more about than this device does: which thread, where it
/// lives, and which relay tally said so.
///
/// Produced by ``BuzzEventStore/threadPrefetchCandidates(channel:limit:)`` and consumed
/// by ``SyncEngine/prefetchThreads(in:)``. The summary's event id travels with the
/// candidate rather than being read back after the fetch, and that is load-bearing —
/// see ``BuzzEventStore/recordThreadPrefetch(root:summaryEventID:)``.
public struct ThreadPrefetchCandidate: Sendable, Hashable {
    /// The thread's root event id, which is what the fetch filters on.
    public let rootID: String
    /// The channel the root was posted in.
    public let channelID: String
    /// The `kind:39005` that was current for this root when the candidate was chosen,
    /// or `nil` if the row carried none.
    public let summaryEventID: String?

    public init(rootID: String, channelID: String, summaryEventID: String?) {
        self.rootID = rootID
        self.channelID = channelID
        self.summaryEventID = summaryEventID
    }
}

public extension BuzzEventStore {
    /// Threads whose relay tally describes a reply newer than anything this device
    /// holds, most recently active first — what a prefetch should go and fetch.
    ///
    /// # The predicate, and why it is a comparison of times rather than of counts
    ///
    /// "The relay counts more replies than I hold" would seem the obvious test and is the
    /// wrong one: it is true of every thread whose newest replies were prefetched under
    /// ``SyncEngineConfig/threadPrefetchReplyLimit`` and will stay true forever, so a
    /// bounded fetch would re-issue itself on every pass. Comparing the *newest* reply
    /// instead converges: a successful fetch pulls the newest reply, local
    /// `MAX(created_at)` rises to exactly the `last_reply_at` it was measured against,
    /// and the row drops out until somebody replies again. A partially held thread is a
    /// settled state, which is what it should be.
    ///
    /// # The brake
    ///
    /// Convergence holds only for threads whose replies this device can *see*. A reply
    /// with no NIP-10 `reply` marker gets no `thread` row at all (``BuzzProjector``
    /// declines it, so a channel timeline can exclude replies with one `NOT EXISTS`),
    /// while the relay counts it and stamps `last_reply_at` from it — so local can never
    /// rise to meet the summary and the predicate is permanently true. `thread_prefetch`
    /// is the floor under that: a candidate whose summary this device has already
    /// *attempted* is not offered again. One attempt per new tally, for every thread,
    /// well-formed or not.
    ///
    /// # Why the root event must be present
    ///
    /// The join to `event` is not only how the channel is resolved — it is a guard. A
    /// thread whose opener this device does not hold cannot render on the Threads screen
    /// (``threadActivity(selfPubkey:limit:)`` joins its root), so fetching its replies
    /// would spend a request on rows nothing can draw. In practice the guard almost never
    /// bites: a `thread_summary` row rides in beside the page row it describes.
    ///
    /// - Parameters:
    ///   - channel: Restrict to one channel's threads, or `nil` for every channel.
    ///   - limit: The most candidates to return.
    nonisolated func threadPrefetchCandidates(channel: String?, limit: Int) throws -> [ThreadPrefetchCandidate] {
        try reader.read { db in
            try Row.fetchAll(db, sql: Self.prefetchCandidatesSQL, arguments: [
                "channel": channel,
                "limit": limit,
            ]).map {
                ThreadPrefetchCandidate(
                    rootID: $0["root_id"],
                    channelID: $0["channel_id"],
                    summaryEventID: $0["summary_event_id"]
                )
            }
        }
    }

    /// The query behind ``threadPrefetchCandidates(channel:limit:)``.
    ///
    /// The newest-held-reply test is a correlated subquery rather than a grouped CTE
    /// joined in: `thread_root` is `(root_id, created_at, event_id)`, so per candidate
    /// this is one index seek for a range maximum, and the rows it runs for are only the
    /// roots that have a summary at all. Grouping the whole `thread` table first would
    /// walk every reply in the store to answer a question about twenty threads.
    ///
    /// `NOT (tp.summary_event_id IS tsum.event_id)` and not `<>`: `IS` is null-safe both
    /// ways, so a root with no prefetch row on file (`NULL`) correctly reads as
    /// never-attempted rather than as neither-true-nor-false. The same reason
    /// ``TimelineQuery`` spells its fetch test with `IS`.
    private static let prefetchCandidatesSQL = """
        SELECT tsum.root_id  AS root_id,
               root.h        AS channel_id,
               tsum.event_id AS summary_event_id
        FROM thread_summary tsum
        JOIN event root ON root.id = tsum.root_id
        LEFT JOIN thread_prefetch tp ON tp.root_id = tsum.root_id
        WHERE tsum.last_reply_at IS NOT NULL
          AND (:channel IS NULL OR root.h = :channel)
          AND NOT (tp.summary_event_id IS tsum.event_id)
          AND tsum.last_reply_at > COALESCE(
                (SELECT MAX(t.created_at) FROM thread t WHERE t.root_id = tsum.root_id), 0)
        ORDER BY tsum.last_reply_at DESC
        LIMIT :limit
        """
}

public extension BuzzEventStore {
    /// Records that a prefetch was attempted for `root` against `summaryEventID`.
    ///
    /// The claim is narrow on purpose — *asked about*, not *hold in full*. A prefetch is
    /// clipped at ``SyncEngineConfig/threadPrefetchReplyLimit`` and so may never suppress
    /// the relay's tally; that is ``recordThreadFetch(root:)``'s claim and only an
    /// unclipped answer earns it. Keeping the two in separate tables is what lets a
    /// bounded fetch have a brake without also having authority.
    ///
    /// # Why the summary id is passed in
    ///
    /// ``recordThreadFetch(root:)`` reads the current summary inside its own statement.
    /// This one must not: a tally arriving mid-fetch describes a reply the fetch cannot
    /// have seen, and recording *that* one would mark it attempted and skip it. Naming
    /// the summary the candidate was selected against means a mid-fetch arrival can only
    /// leave the root candidate for one more pass, which is the safe direction — an extra
    /// request, never a missed reply.
    func recordThreadPrefetch(root: String, summaryEventID: String?) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO thread_prefetch (root_id, summary_event_id)
                VALUES (?, ?)
                ON CONFLICT(root_id) DO UPDATE SET summary_event_id = excluded.summary_event_id
                """,
                arguments: [root, summaryEventID]
            )
        }
    }
}
