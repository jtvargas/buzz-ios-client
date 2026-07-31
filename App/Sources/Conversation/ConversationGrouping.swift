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
    /// A message, and whether it continues the run of messages directly above it — the
    /// same author, close enough in time, with nothing in between. A continuation drops
    /// its author's attribution and sits tighter under the message above; see
    /// ``ConversationGrouping/continues(_:after:)`` for the rule that decides it.
    case message(TimelineRow, continuesGroup: Bool)
    /// A relay notice — somebody joined, was added, or left. Its own case rather than a
    /// flag on ``message`` so that no message renderer can ever be handed one: a
    /// notice's `content` is a JSON body, and a row that fell through to the ordinary
    /// text path would print it.
    case notice(NoticeMarker)

    var id: String {
        switch self {
        case let .day(marker): "day-\(marker.id)"
        case let .message(row, _): row.id
        case let .notice(marker): marker.id
        }
    }

    var message: TimelineRow? {
        switch self {
        case .day, .notice: nil
        case let .message(row, _): row
        }
    }

    /// Whether this item continues the run above it, and so must not have space put
    /// between it and the item before.
    ///
    /// Furniture never continues anything: a day separator and a notice both end whatever
    /// run they land in, which is also why neither can be a continuation itself.
    var continuesGroup: Bool {
        switch self {
        case .day, .notice: false
        case let .message(_, continues): continues
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

/// Turns a conversation's messages into the items a list renders: one day separator
/// wherever the local calendar day changes, and a note on each message saying whether it
/// continues the run above it.
///
/// Pure, so both rules are tested directly: no duplicate separators, none before an empty
/// conversation, the boundary decided in the device's own time zone (the `calendar`
/// argument carries it) rather than UTC — and a run that ends where a reader would say it
/// ends, rather than one decided per surface inside a row.
enum ConversationGrouping {
    /// How long after a message a second one from the same author still reads as the same
    /// breath rather than as a fresh remark.
    ///
    /// Five minutes, Slack's own window and the one the owner asked for. Measured from the
    /// message directly above rather than from the head of the run: what a reader is
    /// judging is the pause between two messages, and a chain of quick follow-ups is one
    /// block however long the chain gets.
    static let groupWindow: TimeInterval = 5 * 60

    /// `rows` in the order they are rendered — oldest first, the order both the
    /// channel timeline and a thread already produce.
    static func items(
        for rows: [TimelineRow],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [ConversationItem] {
        var items: [ConversationItem] = []
        items.reserveCapacity(rows.count + 4)
        var currentDay: String?
        /// The message the previous item was, or `nil` when the previous item was not a
        /// message — which is what makes a day separator or a notice end a run.
        var previous: TimelineRow?
        for row in rows {
            // A notice this build cannot read — a type the relay added since, or a body
            // naming nobody — has no sentence to write, so it is dropped outright rather
            // than falling through to the message path, where its raw JSON body would be
            // rendered as somebody's words. Dropped before the day separator too: an
            // invisible row must not be able to introduce a visible date heading with
            // nothing under it. It leaves the run it fell inside alone, for the same
            // reason: nothing was drawn, so nothing came between.
            if row.isNotice, row.notice == nil { continue }
            let date = row.date
            let key = DaySeparatorLabel.dayKey(for: date, calendar: calendar)
            if key != currentDay {
                currentDay = key
                items.append(.day(DayMarker(id: key, date: date)))
                // Not implied by the time rule: a message at 23:59 and one at 00:00 are
                // forty seconds apart and have a date heading between them.
                previous = nil
            }
            if let notice = row.notice {
                items.append(.notice(NoticeMarker(id: row.id, date: date, notice: notice)))
                previous = nil
            } else {
                items.append(.message(row, continuesGroup: continues(row, after: previous)))
                previous = row
            }
        }
        return items
    }

    /// Whether `row` stacks under `previous` as part of one block, rather than opening a
    /// new one with its author's avatar, name and time.
    ///
    /// The author, the window and the day are the reference client's own rule
    /// (`buzz/mobile`, `message_list.dart`: same pubkey, `createdAt` delta ≤ 300, no day
    /// divider, previous is not a system notice), so a conversation blocks up the same way
    /// on a phone running either app. Two clauses are ours:
    ///
    /// - **A message that carries a picture always names its author.** Upstream's channel
    ///   list does this and its thread page does not; it is right, and it is applied to
    ///   both here. A picture is the thing a reader scrolls back to find, and one hanging
    ///   in the middle of a block has no name and no time anywhere on it.
    /// - **A run may only cover messages that agree about being replies.** The header
    ///   carries a fact besides identity — the glyph that marks a broadcast reply — so
    ///   without this a reply landing under its author's own earlier message would lose the
    ///   only mark that says so. It costs nothing inside a thread, where every row is one.
    private static func continues(_ row: TimelineRow, after previous: TimelineRow?) -> Bool {
        guard let previous,
              previous.pubkey == row.pubkey,
              row.media.isEmpty,
              previous.isReply == row.isReply
        else { return false }
        let gap = row.date.timeIntervalSince(previous.date)
        // A non-negative gap is the normal case — rows arrive sorted — and the guard is
        // for the one that is not: a relay clock running backwards must not be able to
        // group a message under one that appears to come after it.
        return gap >= 0 && gap <= groupWindow
    }
}
