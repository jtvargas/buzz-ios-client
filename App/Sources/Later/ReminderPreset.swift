import Foundation

/// The times a reminder can be set for.
///
/// The four real ones are Buzz desktop's, verbatim, from
/// `desktop/src/features/reminders/lib/timePresets.ts` — so "In 3 hours" on the phone and
/// "In 3 hours" on the desktop mean the same instant. Desktop also offers "Next Monday at
/// 9am"; it is left out here because the owner asked for four.
struct ReminderPreset: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    /// The symbol beside the label. Named per preset rather than one clock for all of
    /// them, so the list can be read by shape at a glance.
    let symbol: String
    /// How the due instant is derived from a given "now". A function rather than a stored
    /// date: a sheet left open for ten minutes must not set a reminder ten minutes stale.
    let due: @Sendable (Date, Calendar) -> Date

    static func == (lhs: ReminderPreset, rhs: ReminderPreset) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ReminderPreset {
    static let inThirtyMinutes = ReminderPreset(
        id: "30m",
        label: "In 30 minutes",
        symbol: "clock"
    ) { now, _ in now.addingTimeInterval(30 * 60) }

    static let inOneHour = ReminderPreset(
        id: "1h",
        label: "In 1 hour",
        symbol: "clock"
    ) { now, _ in now.addingTimeInterval(60 * 60) }

    static let inThreeHours = ReminderPreset(
        id: "3h",
        label: "In 3 hours",
        symbol: "clock"
    ) { now, _ in now.addingTimeInterval(3 * 60 * 60) }

    static let tomorrowMorning = ReminderPreset(
        id: "tomorrow-9am",
        label: "Tomorrow at 9:00 AM",
        symbol: "sunrise"
    ) { now, calendar in Self.nextNineAM(after: now, dayOffset: 1, calendar: calendar) }

    /// The testing option the owner asked for, so a reminder can be seen firing without
    /// waiting half an hour. Deliberately in the same list as the real ones rather than
    /// behind a debug flag — it is only useful where the others are.
    static let inOneMinute = ReminderPreset(
        id: "1m",
        label: "In 1 minute",
        symbol: "hare"
    ) { now, _ in now.addingTimeInterval(60) }

    /// In the order the sheet draws them: soonest first, with the test option last so it
    /// is never the one tapped by accident.
    static let all: [ReminderPreset] = [
        .inThirtyMinutes,
        .inOneHour,
        .inThreeHours,
        .tomorrowMorning,
        .inOneMinute,
    ]

    /// 9am, `dayOffset` days out — rolled forward another day if that instant has already
    /// passed, so "tomorrow at 9" is never a time in the past. Desktop's `nextDayAt9am`.
    static func nextNineAM(after now: Date, dayOffset: Int, calendar: Calendar) -> Date {
        let base = calendar.date(byAdding: .day, value: dayOffset, to: now) ?? now
        var components = calendar.dateComponents([.year, .month, .day], from: base)
        components.hour = 9
        components.minute = 0
        components.second = 0
        guard let candidate = calendar.date(from: components) else {
            return now.addingTimeInterval(24 * 60 * 60)
        }
        guard candidate <= now else { return candidate }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }
}
