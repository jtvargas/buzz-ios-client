import Foundation
import GRDB

/// Who has replied in one thread, oldest reply first.
///
/// A query result, not a stored table: assembled on read by grouping the `thread`
/// projection's reply rows by author, so a thread never has to keep a participant
/// list in step with its replies. A thin wrapper over `[String]` — the shape
/// ``BuzzEventStore/threadParticipants(for:limit:)`` returns per root — conforming to
/// `RandomAccessCollection` so a reply-preview strip can `ForEach` it directly, the
/// same shape ``MentionRefList`` takes.
///
/// Order is the order people arrived: by their *first* surviving reply, ties broken by
/// pubkey. That is what keeps the four faces under a message stable as later replies
/// land — an order derived from the newest reply would reshuffle the strip on every
/// arrival, which reads as the row twitching.
///
/// Pubkeys, deliberately, and not names or artwork: this is a store read, and the app's
/// single identity resolver is the only thing allowed to turn a key into something a
/// reader sees.
public struct ThreadParticipants: Sendable, Hashable, RandomAccessCollection {
    /// The distinct reply authors, first-reply order, no more than the `limit` the
    /// read was asked for.
    public let pubkeys: [String]

    public init(_ pubkeys: [String]) {
        self.pubkeys = pubkeys
    }

    public var startIndex: Int { pubkeys.startIndex }
    public var endIndex: Int { pubkeys.endIndex }
    public subscript(position: Int) -> String { pubkeys[position] }
}

public extension BuzzEventStore {
    /// The distinct people who replied in each of `rootIDs`, keyed by the thread's
    /// root event id, for the reply-preview strip under a threaded message.
    ///
    /// A root with no surviving replies is simply absent from the result — the caller
    /// treats a missing key as "no thread" — so the dictionary carries only what there
    /// is to draw, exactly like ``reactions(for:selfPubkey:)`` and ``mentions(for:)``.
    /// An empty `rootIDs`, or a non-positive `limit`, returns `[:]` without touching
    /// the database.
    ///
    /// Batched for a whole page rather than queried per row: one statement over an `IN`
    /// list, the shape the timeline model already uses for reactions and mentions, so
    /// scrolling a page of threaded messages costs one read and not fifty.
    ///
    /// `limit` has no default on purpose. The cap is what stops a five-hundred-reply
    /// thread from handing back five hundred strings the row will never draw, so the
    /// number belongs to the surface that decides how many faces it shows — and a read
    /// that silently chose it here would be the second place that decision lived.
    ///
    /// # Which replies count
    ///
    /// Exactly the ones ``TimelineRow/replyCount`` counts, so the faces and the number
    /// beside them can never disagree:
    ///
    /// - a reply whose author (or that author's verified NIP-OA owner, or the relay)
    ///   has deleted it contributes no participant, through the *same* read-time
    ///   ``deletionApplies(target:author:owner:)`` predicate the tally applies;
    /// - a broadcast reply — echoed to the channel by its author — still has a `thread`
    ///   row and so still counts, in both places;
    /// - a reply still queued in the outbox counts in neither. It has no `thread` row
    ///   yet, and the tally is derived from that projection too.
    ///
    /// The root's own author is a participant only if they replied. Someone who opened
    /// a thread and said nothing else in it has not participated in it.
    ///
    /// Synchronous and `nonisolated` so it runs on the concurrent reader off the actor,
    /// and so `ValueObservation` can track the `thread`, `deletion`, and `event_owner`
    /// tables it reads — the same discipline as the timeline, reaction, and mention
    /// reads, so a face appears the moment the reply that put it there is ingested.
    nonisolated func threadParticipants(
        for rootIDs: [String],
        limit: Int
    ) throws -> [String: ThreadParticipants] {
        guard !rootIDs.isEmpty, limit > 0 else { return [:] }
        return try reader.read { db in
            try Self.fetchThreadParticipants(db, rootIDs: rootIDs, limit: limit)
        }
    }
}

extension BuzzEventStore {
    /// The participant aggregation, over an open database so an observation can track
    /// it.
    ///
    /// Groups by `(root_id, pubkey)` and keeps each author's earliest surviving reply,
    /// so a person who replied five times is one face at the position they first
    /// spoke. `ORDER BY` carries the whole result's order — root, then first reply,
    /// then pubkey for a same-second tie — which is what makes the per-root prefix
    /// below deterministic rather than dependent on SQLite's grouping order.
    ///
    /// The cap is applied in Swift rather than as a per-group window function: the
    /// aggregation has already collapsed each thread to one row per author, so what
    /// comes back is bounded by the number of *people* in the page's threads, and a
    /// `ROW_NUMBER() OVER (PARTITION BY …)` would buy nothing for the extra surface
    /// area.
    static func fetchThreadParticipants(
        _ db: Database,
        rootIDs: [String],
        limit: Int
    ) throws -> [String: ThreadParticipants] {
        var arguments: [String: (any DatabaseValueConvertible)?] = [:]
        var placeholders: [String] = []
        for (index, id) in rootIDs.enumerated() {
            let key = "r\(index)"
            placeholders.append(":\(key)")
            arguments[key] = id
        }

        let replyDeleted = deletionApplies(
            target: "t.event_id",
            author: "t.pubkey",
            owner: "(SELECT owner_pubkey FROM event_owner WHERE event_id = t.event_id)"
        )

        let sql = """
        SELECT t.root_id          AS root_id,
               t.pubkey           AS pubkey,
               MIN(t.created_at)  AS first_at
        FROM thread t
        WHERE t.root_id IN (\(placeholders.joined(separator: ", ")))
          AND NOT \(replyDeleted)
        GROUP BY t.root_id, t.pubkey
        ORDER BY t.root_id ASC, first_at ASC, t.pubkey ASC
        """

        let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

        var result: [String: [String]] = [:]
        for row in rows {
            let root: String = row["root_id"]
            // The ORDER BY put the earliest replier first, so the first `limit`
            // arrivals per root are simply the first rows seen for it.
            guard result[root, default: []].count < limit else { continue }
            result[root, default: []].append(row["pubkey"])
        }
        return result.mapValues(ThreadParticipants.init)
    }
}
