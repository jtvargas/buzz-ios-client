@testable import BuzzKit
@testable import Hive
import Foundation
import Testing

/// The Phase-5 §6/§7 contract: one timestamp rule set, one day-separator rule set,
/// and separators inserted from the message list rather than decided per row.
@Suite("Conversation time and grouping", .timeLimit(.minutes(1)))
struct ConversationTimeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private let locale = Locale(identifier: "en_US")

    private func date(
        year: Int = 2026,
        month: Int = 7,
        day: Int = 26,
        hour: Int = 12,
        minute: Int = 0
    ) -> Date {
        calendar.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    // MARK: - Message timestamps

    @Test("reads now inside 45 seconds, then counts minutes to twenty")
    func relativeWindow() {
        let now = date(hour: 12, minute: 30)

        #expect(MessageTimestamp.label(for: now, now: now, locale: locale, calendar: calendar) == "now")
        #expect(MessageTimestamp.label(
            for: now.addingTimeInterval(-44),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "now")
        // 45s rounds to the first minute rather than reading "0 min ago".
        #expect(MessageTimestamp.label(
            for: now.addingTimeInterval(-45),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "1 min ago")
        #expect(MessageTimestamp.label(
            for: now.addingTimeInterval(-2 * 60),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "2 min ago")
        #expect(MessageTimestamp.label(
            for: now.addingTimeInterval(-20 * 60),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "20 min ago")
    }

    @Test("past twenty minutes it is a clock time, on this day and every earlier one")
    func absoluteWindow() {
        let now = date(hour: 12, minute: 30)
        let earlierToday = date(hour: 9, minute: 41)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: earlierToday)!

        let today = MessageTimestamp.label(for: earlierToday, now: now, locale: locale, calendar: calendar)
        #expect(today.contains("9:41"))
        #expect(!today.contains("ago"))

        // A previous-day message keeps the plain time: the day separator above it is
        // what carries the date.
        let older = MessageTimestamp.label(for: yesterday, now: now, locale: locale, calendar: calendar)
        #expect(older.contains("9:41"))
        #expect(!older.contains("Jul"))
    }

    @Test("a message dated in the future reads as now rather than negative")
    func clockSkew() {
        let now = date(hour: 12)
        let ahead = now.addingTimeInterval(10 * 60)
        #expect(MessageTimestamp.label(for: ahead, now: now, locale: locale, calendar: calendar) == "now")
    }

    @Test("only messages inside the relative window need the shared clock")
    func relativeGate() {
        let now = date(hour: 12)
        #expect(MessageTimestamp.isRelative(now.addingTimeInterval(-60), now: now))
        #expect(!MessageTimestamp.isRelative(now.addingTimeInterval(-21 * 60), now: now))
    }

    // MARK: - Day separators

    @Test("labels Today, Yesterday, a weekday inside the week, then a date")
    func daySeparatorLabels() {
        // 2026-07-26 is a Sunday.
        let now = date(hour: 12)

        #expect(DaySeparatorLabel.label(
            for: date(hour: 8),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "Today")
        #expect(DaySeparatorLabel.label(
            for: date(day: 25),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "Yesterday")
        // Three days back is still a useful weekday name.
        #expect(DaySeparatorLabel.label(
            for: date(day: 23),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "Thursday")
        // Past the week, the date. No year while the year is obvious.
        #expect(DaySeparatorLabel.label(
            for: date(day: 14),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "Jul 14")
        #expect(DaySeparatorLabel.label(
            for: date(year: 2025, month: 7, day: 24),
            now: now,
            locale: locale,
            calendar: calendar
        ) == "Jul 24, 2025")
    }

    @Test("the day key is the local calendar day, so a separator is stable across a session")
    func dayKeys() {
        let lateNight = date(day: 25, hour: 23, minute: 59)
        let justAfter = date(day: 26, hour: 0, minute: 1)
        #expect(DaySeparatorLabel.dayKey(for: lateNight, calendar: calendar)
            != DaySeparatorLabel.dayKey(for: justAfter, calendar: calendar))
        #expect(DaySeparatorLabel.dayKey(for: date(hour: 1), calendar: calendar)
            == DaySeparatorLabel.dayKey(for: date(hour: 23), calendar: calendar))
    }

    // MARK: - Grouping

    private func row(_ id: String, at date: Date) -> TimelineRow {
        TimelineRow(
            id: id,
            pubkey: "author",
            createdAt: Int64(date.timeIntervalSince1970),
            content: id,
            isEdited: false,
            isDeleted: false,
            richContent: nil,
            delivery: .sent,
            authorName: "Author",
            authorPicture: nil,
            parentID: nil,
            rootID: nil,
            replyCount: 0,
            lastReplyAt: nil
        )
    }

    @Test("inserts one separator per calendar day, in order, with none duplicated")
    func grouping() {
        let rows = [
            row("a", at: date(day: 24, hour: 9)),
            row("b", at: date(day: 24, hour: 18)),
            row("c", at: date(day: 25, hour: 8)),
            row("d", at: date(day: 26, hour: 11)),
            row("e", at: date(day: 26, hour: 12)),
        ]

        let items = ConversationGrouping.items(for: rows, calendar: calendar)

        // Three days, five messages, separators leading each day's first message.
        let separators = items.compactMap { item -> DayMarker? in
            if case let .day(marker) = item { return marker }
            return nil
        }
        #expect(separators.count == 3)
        #expect(Set(separators.map(\.id)).count == 3)
        #expect(items.count == 8)
        #expect(items.compactMap(\.message?.id) == ["a", "b", "c", "d", "e"])

        if case let .day(first) = items[0] {
            #expect(first.id == DaySeparatorLabel.dayKey(for: rows[0].date, calendar: calendar))
        } else {
            Issue.record("the first item should be a day separator")
        }
        if case .message = items[2] {} else {
            Issue.record("the second message of a day should not carry its own separator")
        }

        // Ids are stable and unique, so a lazy stack diffs items in place.
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test("an empty conversation has no separators")
    func emptyGrouping() {
        #expect(ConversationGrouping.items(for: [], calendar: calendar).isEmpty)
    }
}
