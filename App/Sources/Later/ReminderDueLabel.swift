import BuzzKit
import SwiftUI

/// When a reminder is due, as its row says it — and whether that moment has passed.
///
/// Pure, and apart from the view, because this is the one rule on the Later screen with a
/// boundary worth asserting rather than eyeballing: the instant a reminder stops counting
/// down and starts being late is the instant the text turns red, and a rendered row cannot
/// be asked what colour it ended up.
///
/// Phrased off the stored `not_before` rather than off the preset that was chosen. The
/// preset is not in the payload — NIP-ER has no field for it, and inventing one would be a
/// field the desktop client drops — and the remaining time is the more useful fact anyway:
/// it is what the row is counting down to.
enum ReminderDueLabel {
    struct Label: Equatable {
        let text: String
        /// Whether the reminder's time has passed. Drawn in red, which is Slack's signal
        /// for the same state and the one the owner asked for.
        let isOverdue: Bool
    }

    static func label(for row: ReminderRow, now: Date = Date()) -> Label {
        guard let due = row.dueDate else {
            return Label(text: finishedText(for: row.status), isOverdue: false)
        }
        let remaining = due.timeIntervalSince(now)
        if remaining > 0 {
            // Rounded up to a whole minute rather than spelled exactly: under a minute the
            // formatter has no unit left to use and would say `0 minutes`.
            return Label(text: "In \(spell(max(remaining, minimumUnit)))", isOverdue: false)
        }
        let late = -remaining
        // The first minute of being late reads as the thing that just happened, not as a
        // duration — the alert for it is on the screen while this is true.
        guard late >= minimumUnit else { return Label(text: "Due now", isOverdue: true) }
        return Label(text: "\(spell(late)) ago", isOverdue: true)
    }

    /// A reminder that is finished carries no due time — that is what NIP-ER says a done or
    /// cancelled one looks like — so its line says which of the two it is instead.
    private static func finishedText(for status: ReminderStatus) -> String {
        switch status {
        case .done: "Completed"
        case .cancelled: "Archived"
        // Pending with no due time is a shape nothing here writes; it is not worth a
        // sentence, and it must not be worth a crash.
        case .pending: "Due soon"
        }
    }

    /// The smallest span this label spells. Below it there is no unit to spell.
    private static let minimumUnit: TimeInterval = 60

    /// `25 minutes`, `3 hours`, `2 days` — one unit, because the second one is noise on a
    /// line whose job is to be read at a glance.
    ///
    /// Rounded to the nearest minute *before* it is spelled, and before the unit is chosen.
    /// `DateComponentsFormatter` truncates, and a due time is stored as a whole second while
    /// the moment it was chosen was not — so picking **In 30 minutes** hands this 1799.6 and
    /// an untruncated formatter answers `29 minutes`, immediately, on the row you just made.
    /// The same fraction turns a three-hour reminder into `2 hours`.
    private static func spell(_ interval: TimeInterval) -> String {
        let rounded = (interval / minimumUnit).rounded() * minimumUnit
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = rounded < 3600 ? [.minute] : [.day, .hour]
        formatter.maximumUnitCount = 1
        guard let spelled = formatter.string(from: rounded), !spelled.isEmpty else {
            // Unreachable with the units above, and cheaper than an optional every caller
            // would have to answer for.
            return "a moment"
        }
        return spelled
    }
}

/// The due line on a Later row, and the only view on that row that watches the clock.
///
/// Its own leaf for the reason ``MessageTimestampView`` is: a tick has to be able to turn
/// this one `Text` red without invalidating the avatar, the preview and the two buttons
/// beside it. Without the shared clock the label is still correct when it is drawn — it
/// simply never ages, which is what a preview or a test host gets.
struct ReminderDueLabelView: View {
    let row: ReminderRow

    @Environment(\.relativeTimeTicker) private var ticker

    var body: some View {
        let label = ReminderDueLabel.label(for: row, now: ticker?.now ?? Date())
        Text(label.text)
            .font(.hive(.caption, weight: label.isOverdue ? .semibold : .regular))
            .foregroundStyle(label.isOverdue ? Color.red : Color.secondary)
            .lineLimit(1)
            // Never the part of the line that truncates: the channel name beside it can lose
            // its tail and still say where this came from, and this cannot.
            .fixedSize(horizontal: true, vertical: false)
    }
}
