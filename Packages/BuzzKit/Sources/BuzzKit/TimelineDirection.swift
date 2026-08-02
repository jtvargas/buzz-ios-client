import Foundation

/// Which way a page reads from its cursor.
///
/// A conversation is read backwards — newest first, paging into history — and that stays
/// the default everywhere. Landing on a linked message is the exception: it wants the rows
/// *after* the target as much as the ones before, and ``TimelineCursor`` is a symmetric
/// keyset, so one query serves both by flipping its comparison and its order together.
///
/// Together is the whole of it. The per-branch bound in
/// ``BuzzEventStore/fetchTimeline(_:channel:from:direction:limit:)`` is sound only while
/// every branch orders the same way as the outer query, and a branch left on the other
/// order does not fail loudly — it drops rows that belonged in the page. That is why the
/// two properties below are the only spelling of either: nothing downstream writes `DESC`
/// or `<` itself, so a caller cannot set one without the other.
///
/// Its own file rather than a member of ``TimelineCursor``'s: the cursor is a *position*
/// and is direction-neutral — the same `(created_at, id)` pair is a valid anchor for a read
/// in either direction — and folding the two together would suggest a position knows which
/// way it is being read.
public enum TimelineDirection: Sendable, Equatable {
    /// Newest first, rows strictly older than the cursor — a conversation's own paging.
    case descending
    /// Oldest first, rows strictly newer than the cursor.
    case ascending

    /// The comparison a keyset predicate makes against the cursor, for both the
    /// timestamp and the id tiebreak.
    ///
    /// Internal, not public: it is SQL fragment text, and the only legitimate reader is
    /// ``BuzzEventStore/page(_:_:_:)`` in this module.
    var comparison: String {
        switch self {
        case .descending: "<"
        case .ascending: ">"
        }
    }

    /// The `ORDER BY` direction every branch **and** the outer query must carry.
    var sqlOrder: String {
        switch self {
        case .descending: "DESC"
        case .ascending: "ASC"
        }
    }
}
