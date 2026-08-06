import Foundation
import GRDB
import NostrCore

/// Reading particular messages by id, through the timeline's own row query.
///
/// Its own file so ``Timeline.swift`` stays the row shape and the two paging reads. The
/// pieces this shares with them — `timelineColumns`, `eventBranch`, `makeRows`, in
/// ``TimelineQuery.swift`` — are internal rather than private for exactly this: a third
/// caller reading the same row shape must select the same columns and build the same
/// struct, or it is a second definition of what a message is.
public extension BuzzEventStore {
    /// The current state of particular timeline rows, by id, in no guaranteed order.
    /// "Rows" and not "messages": the same kinds the channel page returns, notices
    /// included, so a caller can hand back ids from a page without sorting them first.
    ///
    /// A paging read speaks only for its own window: the newest page says nothing about a
    /// row an older page brought in, so a surface holding rows from several pages has no
    /// way to learn that one of them gained a reply. This is that way — one indexed read
    /// over exactly the ids a caller already holds, through the same
    /// ``eventBranch(where:)`` the paging reads use, so a refreshed row is the same row
    /// the page would have returned.
    ///
    /// Log rows only (see ``fetchRows(_:ids:)``): an id still in the outbox is absent
    /// rather than wrong, and a pending send has no tally to refresh anyway.
    ///
    /// Synchronous and `nonisolated` for the reason the paging reads are — it runs on
    /// the concurrent reader, off the actor.
    nonisolated func rows(for ids: [String], selfPubkey: String? = nil) throws -> [TimelineRow] {
        guard !ids.isEmpty else { return [] }
        return try reader.read { db in try Self.fetchRows(db, ids: ids, selfPubkey: selfPubkey) }
    }
}

extension BuzzEventStore {
    /// Particular messages by id, in no guaranteed order.
    ///
    /// The same ``eventBranch(where:)`` the timeline and a thread read through, so a
    /// message fetched this way carries the newest authorized edit, its deletion state,
    /// its rich content, and its author's resolved name — identical to how it renders
    /// where it lives. That is the point: a summary screen that resolved content its own
    /// way would show pre-edit text for a message the thread behind it shows edited.
    ///
    /// Log rows only, no outbox branch: a caller asks for ids it already has, and those
    /// come from the log. An id that is not in the log is simply absent from the result.
    ///
    /// # Why the kinds match ``fetchTimeline(_:channel:before:limit:)``
    ///
    /// The channel page returns messages *and* kind-40099 relay notices, so a caller
    /// holding a page holds ids of both. Filtering to the message kind here would make a
    /// notice an id this read silently returns nothing for — a row the timeline calls a
    /// row and this one does not, which is the second definition of a message the file
    /// header exists to prevent. A notice is not inert, either: a relay tombstone applies
    /// to one through the same `deleted` predicate as any other row.
    ///
    /// The `IN` costs nothing here, unlike in the page query. That one has an `ORDER BY`
    /// the `event_timeline` index satisfies, and widening its kind predicate would trade
    /// an ordered scan for a full sort — which is why it took a third union branch. This
    /// read has no `ORDER BY` at all and is driven by the id set through the primary key,
    /// so the kind predicate is a filter on already-located rows. Confirmed with
    /// `EXPLAIN QUERY PLAN` against this schema: the plan is unchanged either way.
    static func fetchRows(
        _ db: Database,
        ids: [String],
        selfPubkey: String? = nil
    ) throws -> [TimelineRow] {
        guard !ids.isEmpty else { return [] }
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "kind": EventKind.channelMessage.rawValue,
            "noticeKind": EventKind.systemMessage.rawValue,
        ]
        var placeholders: [String] = []
        for (index, id) in ids.enumerated() {
            let key = "r\(index)"
            placeholders.append(":\(key)")
            arguments[key] = id
        }

        let sql = """
        SELECT \(timelineColumns)
        FROM (
            \(eventBranch(where: """
                e.kind IN (:kind, :noticeKind)
                  AND e.id IN (\(placeholders.joined(separator: ", ")))
                """))
        )
        """
        return makeRows(
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)),
            selfPubkey: selfPubkey
        )
    }

}
