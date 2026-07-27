import Foundation
import GRDB
import NostrCore

/// Reading particular messages by id, through the timeline's own row query.
///
/// Its own file so ``Timeline.swift`` stays the two paging reads and the query pieces
/// they share. The pieces themselves — `timelineColumns`, `eventBranch`, `makeRows` — are
/// internal rather than private for exactly this: a third caller reading the same row
/// shape must select the same columns and build the same struct, or it is a second
/// definition of what a message is.
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
    static func fetchRows(_ db: Database, ids: [String]) throws -> [TimelineRow] {
        guard !ids.isEmpty else { return [] }
        var arguments: [String: (any DatabaseValueConvertible)?] = [
            "kind": EventKind.channelMessage.rawValue,
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
                e.kind = :kind AND e.id IN (\(placeholders.joined(separator: ", ")))
                """))
        )
        """
        return makeRows(try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments)))
    }

}
