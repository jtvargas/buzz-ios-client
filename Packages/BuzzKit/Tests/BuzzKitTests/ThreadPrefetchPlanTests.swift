@testable import BuzzKit
import Foundation
import GRDB
import NostrCore
import Testing

/// What the candidate query actually does, read off the planner rather than assumed.
///
/// The prefetch runs on arrival at a screen, so it is not on a per-commit path — but its
/// driving table grows with a channel's history, and the newest-held-reply test is a
/// correlated subquery evaluated per candidate row. Both are exactly the shape that reads
/// fine and scans a table: written as a grouped CTE over `thread` it would walk every reply
/// in the store to answer a question about twenty threads, and the difference is invisible
/// in a test with three replies in it.
@Suite("Thread prefetch query plan", .timeLimit(.minutes(1)))
struct ThreadPrefetchPlanTests {
    @Test("the newest-held-reply test is an index seek, not a scan of the replies")
    func candidateSelectionSeeks() async throws {
        let database = TempDatabase()
        defer { database.remove() }
        let store = try database.open()
        let author = try Fixture()
        let relay = try Fixture()

        let root = try author.message("opener", in: "room-1", at: 1_000)
        let content = """
        {"reply_count":1,"descendant_count":1,"last_reply_at":1400,"participants":[]}
        """
        _ = try await store.ingest(batch: [
            root,
            try relay.event(
                .threadSummary, content,
                tags: [["e", root.id], ["d", root.id], ["h", "room-1"]], at: 1_700_000_500
            ),
        ], phase: .backfill)

        // `detail` and not the first column: EXPLAIN QUERY PLAN's row is
        // (id, parent, notused, detail), so `String.fetchAll` would collect node numbers.
        let plan: [String] = try await store.reader.read { db in
            try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN
            SELECT tsum.root_id, root.h, tsum.event_id
            FROM thread_summary tsum
            JOIN event root ON root.id = tsum.root_id
            LEFT JOIN thread_prefetch tp ON tp.root_id = tsum.root_id
            WHERE tsum.last_reply_at IS NOT NULL
              AND (NULL IS NULL OR root.h = NULL)
              AND NOT (tp.summary_event_id IS tsum.event_id)
              AND tsum.last_reply_at > COALESCE(
                    (SELECT MAX(t.created_at) FROM thread t WHERE t.root_id = tsum.root_id), 0)
            ORDER BY tsum.last_reply_at DESC
            LIMIT 20
            """, arguments: []).map { $0["detail"] ?? "" }
        }
        let text = plan.joined(separator: "\n")

        // The two joins and the correlated maximum all reach their row by key. `thread` in
        // particular must be a search on `thread_root` — a `SCAN thread` here is the whole
        // reply history walked once per candidate.
        #expect(!text.contains("SCAN thread "), "the replies are being scanned: \n\(text)")
        #expect(!text.contains("SCAN event"), "the log is being scanned: \n\(text)")
        #expect(text.contains("USING COVERING INDEX thread_root"),
                "the correlated maximum is not seeking thread_root: \n\(text)")
        // And the summaries are walked newest-first through their own index rather than
        // scanned and sorted, so the `LIMIT` can stop early instead of the read paying for
        // every thread that has ever had a reply. This is the assertion that would have
        // caught the index being absent, which is how it shipped in the first draft.
        #expect(text.contains("thread_summary_recent"),
                "the summaries are not being walked in recency order: \n\(text)")
        #expect(!text.contains("TEMP B-TREE"), "the read is sorting: \n\(text)")
    }
}
