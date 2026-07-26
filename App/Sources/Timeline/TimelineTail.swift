import BuzzKit
import Foundation

/// The rendered tail of a conversation while its reader is not at the bottom.
///
/// # Why a freeze and not a scroll-position trick
///
/// A bottom-anchored scroll view keeps the *distance to the bottom* across a content
/// size change (that is what makes an older page arrive invisibly), which means a
/// message arriving while someone reads history moves what they are looking at up by
/// the height of the new row. Chasing that with a scroll offset correction is a race
/// against layout. Not rendering the arrival until the reader asks for it is not: the
/// content height simply does not change.
///
/// So this value holds the boundary, and the timeline reports how many rows are
/// waiting behind it — one implementation for the channel timeline and a thread, and
/// testable without a view host.
///
/// # Why a cursor and not a timestamp
///
/// The boundary is a `(createdAt, id)` position, not a bare `created_at`. A relay
/// hands out many events in the same second — the reason ``TimelineCursor`` exists at
/// all — so a timestamp-only boundary would let a same-second arrival through the
/// very boundary it was meant to stop.
struct TimelineTail: Equatable {
    /// The newest row that may render, or `nil` when nothing is held back.
    private var boundary: TimelineCursor?

    /// Whether arrivals are currently held back.
    var isFrozen: Bool { boundary != nil }

    /// Holds every row newer than `row` back. A `nil` row — an empty conversation —
    /// freezes nothing, so the first message to arrive in a channel someone is
    /// staring at still appears.
    mutating func freeze(at row: TimelineRow?) {
        boundary = row.map(TimelineCursor.init(row:))
    }

    /// Renders everything again.
    mutating func release() {
        boundary = nil
    }

    /// Splits the full loaded set — ascending by `(createdAt, id)` — into the rows to
    /// render and the count held back behind the boundary.
    func split(_ ordered: [TimelineRow]) -> (rendered: [TimelineRow], heldBack: Int) {
        guard let boundary else { return (ordered, 0) }
        let rendered = ordered.prefix { !Self.follows($0, boundary) }
        return (Array(rendered), ordered.count - rendered.count)
    }

    /// Whether `row` sorts after `cursor` in the `(createdAt, id)` total order the
    /// keyset query pages on — the same order the timeline sorts its rows by, so the
    /// boundary means the same thing in both places.
    private static func follows(_ row: TimelineRow, _ cursor: TimelineCursor) -> Bool {
        (row.createdAt, row.id) > (cursor.createdAt, cursor.id)
    }
}
