import Foundation

/// The one place a message's time becomes text.
///
/// Slack's rule, which the product owner specified: a brand-new message reads
/// `now`, the next twenty minutes read `3 min ago`, and everything older reads as a
/// plain local time — the day it belongs to is carried by the day separator above
/// it, not repeated on every row. Pure and injectable so the boundaries are tested
/// rather than eyeballed.
enum MessageTimestamp {
    /// Below this age a message reads `now`.
    static let nowWindow: TimeInterval = 45
    /// Up to this age a message reads `N min ago`; past it, a clock time.
    static let relativeWindow: TimeInterval = 20 * 60

    /// The label for a message sent at `date`, as of `now`.
    static func label(
        for date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let elapsed = now.timeIntervalSince(date)
        // A message from the future is clock skew, not the future: the relay accepts
        // a ±15-minute window, so treat anything ahead of us as brand new.
        guard elapsed >= nowWindow else { return "now" }
        if elapsed <= relativeWindow {
            let minutes = max(1, Int((elapsed / 60).rounded()))
            return "\(minutes) min ago"
        }
        return time(for: date, locale: locale, calendar: calendar)
    }

    /// Whether `date` still falls in the live-updating window — the gate a row uses
    /// to decide whether its timestamp needs the shared ticker at all.
    static func isRelative(_ date: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(date) <= relativeWindow
    }

    /// The local clock time, in the locale's own convention (`9:41 AM` or `21:41`).
    static func time(
        for date: Date,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        date.formatted(
            Date.FormatStyle(
                date: .omitted,
                time: .shortened,
                locale: locale,
                calendar: calendar,
                timeZone: calendar.timeZone
            )
        )
    }
}

/// The label on a Slack-style day separator: `Today`, `Yesterday`, `Friday` inside
/// the last week, then `Jul 24`, and `Jul 24, 2025` once the year stops being
/// obvious. Always in the device's own time zone, because the separator's whole job
/// is to say which local day a reader is looking at.
enum DaySeparatorLabel {
    static func label(
        for date: Date,
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }

        let base = Date.FormatStyle(
            date: .omitted,
            time: .omitted,
            locale: locale,
            calendar: calendar,
            timeZone: calendar.timeZone
        )

        // Inside the last week a weekday name is the fastest thing to read; beyond
        // it, weekday names start to mean the wrong week.
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: today),
           day >= weekAgo, day < today {
            return date.formatted(base.weekday(.wide))
        }

        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let style = base.month(.abbreviated).day()
        return date.formatted(sameYear ? style : style.year())
    }

    /// The stable identity of the day `date` falls in — the key a separator row is
    /// diffed by, so it is never torn down and rebuilt as messages stream in.
    static func dayKey(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
    }
}
