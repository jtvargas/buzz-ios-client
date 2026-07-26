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
/// # Why a second plus that second's membership, and not a keyset cursor
///
/// A relay hands out many events in the same second — the reason ``TimelineCursor``
/// exists at all — and the question a freeze asks is *"did this row exist when the
/// reader stopped looking?"*, which a `(created_at, id)` position cannot express when
/// the boundary's second has ties. An arrival in that second whose event id sorts
/// *below* the boundary's compares as older and renders straight through the boundary
/// it was meant to stop; ids are hashes, so that was a coin flip per same-second
/// arrival. Recording which ids the boundary second already held answers the question
/// about existence rather than about order.
struct TimelineTail: Equatable {
    /// What was on screen when the freeze was taken, or `nil` when nothing is held
    /// back.
    private var boundary: Boundary?

    /// Whether arrivals are currently held back.
    var isFrozen: Bool { boundary != nil }

    /// Holds back every row that was not already present when the freeze was taken.
    ///
    /// - Parameters:
    ///   - row: the newest row on screen — the boundary itself, which always renders.
    ///     A `nil` row (an empty conversation) freezes nothing, so the first message to
    ///     arrive in a channel someone is staring at still appears.
    ///   - present: the rows loaded at this moment, which supply the ids that already
    ///     exist in the boundary's own second. Rows from other seconds are ignored.
    mutating func freeze(at row: TimelineRow?, among present: [TimelineRow]) {
        guard let row else {
            boundary = nil
            return
        }
        var presentIDs = Set(present.lazy.filter { $0.createdAt == row.createdAt }.map(\.id))
        // Inserted rather than assumed: a caller that hands over a set the boundary row
        // is not in would otherwise hold back the very row the reader is looking at,
        // shrinking the content instead of leaving it alone.
        presentIDs.insert(row.id)
        boundary = Boundary(createdAt: row.createdAt, presentIDs: presentIDs)
    }

    /// Renders everything again.
    mutating func release() {
        boundary = nil
    }

    /// Splits the full loaded set — ascending by `(createdAt, id)` — into the rows to
    /// render and the rows held back behind the boundary.
    ///
    /// A partition rather than a prefix: a held-back row can sort *below* the boundary
    /// in the total order when it shares the boundary's second, so the held set is not
    /// always a suffix. Taking a prefix would drop the boundary row itself along with
    /// it — shrinking the content, which is the exact movement the freeze exists to
    /// prevent.
    ///
    /// The held rows come back as rows rather than as a count because the affordance
    /// above the composer needs both halves of "3 new messages": how many, and *which
    /// one to land on* — the oldest of them, which is `held.first` in the same ascending
    /// order the rendered set keeps.
    func split(_ ordered: [TimelineRow]) -> (rendered: [TimelineRow], held: [TimelineRow]) {
        guard let boundary else { return (ordered, []) }
        var rendered: [TimelineRow] = []
        rendered.reserveCapacity(ordered.count)
        var held: [TimelineRow] = []
        for row in ordered {
            if boundary.holdsBack(row) {
                held.append(row)
            } else {
                rendered.append(row)
            }
        }
        return (rendered, held)
    }

    /// The frozen boundary: a second, and everything that second already held.
    private struct Boundary: Equatable {
        /// The newest `created_at` on screen when the freeze was taken.
        let createdAt: Int64
        /// Every row id that already existed at ``createdAt``.
        let presentIDs: Set<String>

        /// Whether `row` arrived after the freeze — strictly later than the boundary
        /// second, or inside it but not among the ids it already held.
        func holdsBack(_ row: TimelineRow) -> Bool {
            if row.createdAt > createdAt { return true }
            return row.createdAt == createdAt && !presentIDs.contains(row.id)
        }
    }
}
