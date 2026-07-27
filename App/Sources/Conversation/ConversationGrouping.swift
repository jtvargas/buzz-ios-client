import BuzzKit
import Foundation

/// One element of a rendered conversation.
///
/// The day separators a reader sees are not messages, so they are not smuggled into
/// the row view as a header on the first message of a day — that trick puts the
/// grouping decision in the row, where a thread, a DM, and a channel each get their
/// own subtly different copy of it. Instead the model-side grouping produces one
/// ordered list of items and every surface renders the same two cases.
enum ConversationItem: Identifiable, Hashable {
    case day(DayMarker)
    case message(TimelineRow)

    var id: String {
        switch self {
        case let .day(marker): "day-\(marker.id)"
        case let .message(row): row.id
        }
    }

    var message: TimelineRow? {
        switch self {
        case .day: nil
        case let .message(row): row
        }
    }
}

extension [ConversationItem] {
    /// The id of the newest message in this list — what the scaffold lands on when it has to
    /// reach "the newest message". See ``ConversationScaffold/newestID``.
    ///
    /// Searched from the end and skipping day separators, rather than taken from `last`. A
    /// separator only ever precedes the messages of its day, so today the final element is
    /// always a message; the search costs one comparison in that case, and it means a future
    /// trailing element — a typing indicator, an unread rule — cannot silently become the
    /// thing a conversation scrolls to.
    var newestMessageID: String? {
        last { $0.message != nil }?.id
    }
}

/// The day a separator marks: its stable key and a date inside it to format.
struct DayMarker: Identifiable, Hashable {
    let id: String
    let date: Date
}

/// Turns a conversation's messages into the items a list renders, inserting one day
/// separator wherever the local calendar day changes.
///
/// Pure, so the separator rules are tested directly: no duplicate separators, none
/// before an empty conversation, and the boundary decided in the device's own time
/// zone (the `calendar` argument carries it) rather than UTC.
enum ConversationGrouping {
    /// `rows` in the order they are rendered — oldest first, the order both the
    /// channel timeline and a thread already produce.
    static func items(
        for rows: [TimelineRow],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ConversationItem] {
        var items: [ConversationItem] = []
        items.reserveCapacity(rows.count + 4)
        var currentDay: String?
        for row in rows {
            let date = row.date
            let key = DaySeparatorLabel.dayKey(for: date, calendar: calendar)
            if key != currentDay {
                currentDay = key
                items.append(.day(DayMarker(id: key, date: date)))
            }
            items.append(.message(row))
        }
        return items
    }
}
