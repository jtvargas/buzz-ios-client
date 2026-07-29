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
    /// A relay notice — somebody joined, was added, or left. Its own case rather than a
    /// flag on ``message`` so that no message renderer can ever be handed one: a
    /// notice's `content` is a JSON body, and a row that fell through to the ordinary
    /// text path would print it.
    case notice(NoticeMarker)

    var id: String {
        switch self {
        case let .day(marker): "day-\(marker.id)"
        case let .message(row): row.id
        case let .notice(marker): marker.id
        }
    }

    var message: TimelineRow? {
        switch self {
        case .day, .notice: nil
        case let .message(row): row
        }
    }

    /// Whether this item is something that happened in the conversation, as opposed to
    /// furniture the grouping inserted. A day separator is not content; a message and a
    /// notice both are.
    var isContent: Bool {
        switch self {
        case .day: false
        case .message, .notice: true
        }
    }
}

extension [ConversationItem] {
    /// The id of the newest thing that happened in this list — what the scaffold lands on
    /// when it has to reach the bottom. See ``ConversationScaffold/newestID``.
    ///
    /// Searched from the end and skipping day separators, rather than taken from `last`. A
    /// separator only ever precedes the rows of its day, so today the final element is
    /// always content; the search costs one comparison in that case, and it means a future
    /// trailing element — a typing indicator, an unread rule — cannot silently become the
    /// thing a conversation scrolls to.
    ///
    /// A relay notice counts. A channel whose last event is "Sentry was added by You"
    /// should land on that line and not on the message above it, which would leave the
    /// newest thing in the conversation below the fold.
    var newestMessageID: String? {
        last(where: \.isContent)?.id
    }
}

/// The day a separator marks: its stable key and a date inside it to format.
struct DayMarker: Identifiable, Hashable {
    let id: String
    let date: Date
}

/// A relay notice as a conversation renders it: the decoded facts, its event id, and
/// when it happened.
///
/// Carries the decoded ``SystemNotice`` rather than the ``TimelineRow`` it came from,
/// so nothing downstream can reach the row's raw JSON `content` by accident. The date
/// is here because a notice sits between messages and the day separators are decided
/// over it too.
struct NoticeMarker: Identifiable, Hashable {
    let id: String
    let date: Date
    let notice: SystemNotice
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
            // A notice this build cannot read — a type the relay added since, or a body
            // naming nobody — has no sentence to write, so it is dropped outright rather
            // than falling through to the message path, where its raw JSON body would be
            // rendered as somebody's words. Dropped before the day separator too: an
            // invisible row must not be able to introduce a visible date heading with
            // nothing under it.
            if row.isNotice, row.notice == nil { continue }
            let date = row.date
            let key = DaySeparatorLabel.dayKey(for: date, calendar: calendar)
            if key != currentDay {
                currentDay = key
                items.append(.day(DayMarker(id: key, date: date)))
            }
            if let notice = row.notice {
                items.append(.notice(NoticeMarker(id: row.id, date: date, notice: notice)))
            } else {
                items.append(.message(row))
            }
        }
        return items
    }
}
