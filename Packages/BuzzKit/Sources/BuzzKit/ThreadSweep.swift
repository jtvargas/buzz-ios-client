import Foundation
import GRDB
import NostrCore

/// A thread the sweep will ask about directly, and the point in time it will ask from.
///
/// Produced by ``BuzzEventStore/threadSweepCandidates(identity:horizon:staleBefore:limit:)``
/// and consumed by ``SyncEngine/settleThreadSweep(generation:)``. Unlike a
/// ``ThreadPrefetchCandidate`` it carries no summary event id, because no summary selected
/// it — that is the whole distinction between the two candidate sources.
extension Schema {
    /// The table behind ``BuzzEventStore/threadSweepCandidates(identity:horizon:staleBefore:limit:)``,
    /// registered by the `v12.thread-sweep` migration. Its reasoning lives at that
    /// registration; it is spelled here so it sits beside its only two readers, and because
    /// `Schema`'s own body is at swiftlint's `type_body_length` ceiling.
    static func createThreadSweepTable(_ db: Database) throws {
        try db.execute(sql: """
        CREATE TABLE thread_sweep (
            root_id  TEXT PRIMARY KEY NOT NULL,
            swept_at INTEGER NOT NULL
        )
        """)
    }
}

public struct ThreadSweepCandidate: Sendable, Hashable {
    /// The thread's root event id, which is what the fetch filters on.
    public let rootID: String
    /// The channel the root was posted in.
    public let channelID: String
    /// The `created_at` of the newest reply this device holds for the thread, or the root's
    /// own if it holds none — the `since` the fetch carries, so a thread that has not
    /// changed answers with nothing rather than with its whole history.
    public let since: Int64

    public init(rootID: String, channelID: String, since: Int64) {
        self.rootID = rootID
        self.channelID = channelID
        self.since = since
    }
}

public extension BuzzEventStore {
    /// Threads worth asking the relay about directly, least-recently-asked first.
    ///
    /// # Why this exists beside ``threadPrefetchCandidates(channel:limit:)``
    ///
    /// That one selects on `thread_summary.last_reply_at > local MAX(created_at)`: the relay
    /// says it has something newer. It is the right question whenever the tally is fresh,
    /// and it is unanswerable when the tally is stale — a root behind the sync watermark is
    /// never re-paged, so its `last_reply_at` never rises, so it is never a candidate. The
    /// launch prefetch skips precisely the threads that have silently fallen behind.
    ///
    /// This query asks nothing of the relay's assertions. Candidacy is entirely local: a
    /// root this device holds, in a channel this identity is a member of, inside `horizon`,
    /// that has not been swept since `staleBefore`.
    ///
    /// # The ordering, which is the load-bearing part
    ///
    /// Never-swept roots first, then least-recently-swept, and only then newest-first. That
    /// is what lets `limit` be a per-pass throughput cap rather than a coverage ceiling: a
    /// pass records what it asked, so the next pass's least-recently-swept roots are the
    /// ones the last pass did not reach. Ordering by recency alone would re-serve the same
    /// capful on every launch and leave everything behind it permanently unswept — the
    /// same shape of blind spot this sweep exists to close.
    ///
    /// # Why the root must be top-level and held
    ///
    /// `NOT EXISTS (… thread …)` excludes events that are themselves replies, which is how
    /// ``TimelineQuery`` spells the same distinction. Asking about a reply's `e` tag would
    /// fetch its siblings under the wrong root. Driving from `event` rather than from
    /// `thread_summary` is the point of the whole query: a root whose conversation this
    /// device knows nothing about has no summary and no reply rows, and is exactly the case
    /// that needs sweeping.
    ///
    /// - Parameters:
    ///   - identity: The reader, whose membership scopes which channels are swept.
    ///   - horizon: The oldest root `created_at` worth asking about.
    ///   - staleBefore: A root swept at or after this is skipped. See
    ///     ``SyncEngine/settleThreadSweep(generation:)`` for what the engine passes and why.
    ///   - limit: The most candidates to return.
    nonisolated func threadSweepCandidates(
        identity: String,
        horizon: Int64,
        staleBefore: Int64,
        limit: Int
    ) throws -> [ThreadSweepCandidate] {
        try reader.read { db in
            try Row.fetchAll(db, sql: Self.sweepCandidatesSQL, arguments: [
                "identity": identity.lowercased(),
                "horizon": horizon,
                "staleBefore": staleBefore,
                "kind": EventKind.channelMessage.rawValue,
                "limit": limit,
            ]).map {
                ThreadSweepCandidate(
                    rootID: $0["root_id"],
                    channelID: $0["channel_id"],
                    since: $0["since"]
                )
            }
        }
    }

    /// The query behind ``threadSweepCandidates(identity:horizon:staleBefore:limit:)``.
    ///
    /// `ts.swept_at IS NULL` leads the `ORDER BY` rather than relying on SQLite sorting
    /// NULLs first: that is true of SQLite today and is not something a candidate ordering
    /// this depends on should inherit silently from the engine's collation rules.
    ///
    /// The `since` is a correlated `MAX` over `thread_root (root_id, created_at, event_id)`,
    /// so it is one index seek for a range maximum per candidate row — the same shape, for
    /// the same reason, as the prefetch's newest-held-reply test.
    private static let sweepCandidatesSQL = """
        SELECT root.id AS root_id,
               root.h  AS channel_id,
               COALESCE(
                 (SELECT MAX(t.created_at) FROM thread t WHERE t.root_id = root.id),
                 root.created_at
               ) AS since
        FROM event root
        JOIN channel_member cm ON cm.channel_id = root.h AND cm.pubkey = :identity
        LEFT JOIN thread_sweep ts ON ts.root_id = root.id
        WHERE root.kind = :kind
          AND root.h IS NOT NULL
          AND root.created_at >= :horizon
          AND NOT EXISTS (SELECT 1 FROM thread reply WHERE reply.event_id = root.id)
          AND (ts.swept_at IS NULL OR ts.swept_at < :staleBefore)
        ORDER BY ts.swept_at IS NULL DESC, ts.swept_at ASC, root.created_at DESC
        LIMIT :limit
        """
}

public extension BuzzEventStore {
    /// Records that the given roots were swept at `at`.
    ///
    /// Written per batch, after the batch's events have been ingested, for the same reason
    /// ``recordThreadPrefetch(root:summaryEventID:)`` is: a batch whose request or write
    /// failed must leave no record, so the next pass asks again from the same place rather
    /// than counting a dropped socket as an answer.
    ///
    /// The claim is only *asked*, never *held in full* — a sweep is clipped at the same
    /// reply budget as a prefetch, so it may never suppress a relay tally. That authority
    /// belongs to ``recordThreadFetch(root:)`` and only an unclipped answer earns it.
    func recordThreadSweep(roots: [String], at: Int64) async throws {
        guard !roots.isEmpty else { return }
        try await writer.write { db in
            for root in roots {
                try db.execute(
                    sql: """
                    INSERT INTO thread_sweep (root_id, swept_at)
                    VALUES (?, ?)
                    ON CONFLICT(root_id) DO UPDATE SET swept_at = excluded.swept_at
                    """,
                    arguments: [root, at]
                )
            }
        }
    }
}
