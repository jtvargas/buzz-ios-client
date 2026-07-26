@testable import Hive
import Foundation
import Testing

@Suite("Phase 4 UX", .timeLimit(.minutes(1)))
struct Phase4UXTests {
    @Test("thread summary uses Today and Yesterday relative to the supplied day")
    func replySummaryDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let now = calendar.date(from: DateComponents(
            year: 2025,
            month: 7,
            day: 18,
            hour: 12
        ))!
        let today = calendar.date(from: DateComponents(
            year: 2025,
            month: 7,
            day: 18,
            hour: 9,
            minute: 41
        ))!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let todayLabel = ThreadSummaryDateFormatter.label(
            for: today,
            relativeTo: now,
            calendar: calendar,
            locale: locale
        )
        let yesterdayLabel = ThreadSummaryDateFormatter.label(
            for: yesterday,
            relativeTo: now,
            calendar: calendar,
            locale: locale
        )

        #expect(todayLabel.hasPrefix("Today at "))
        #expect(todayLabel.contains("9:41"))
        #expect(yesterdayLabel.hasPrefix("Yesterday at "))
        #expect(yesterdayLabel.contains("9:41"))
    }
}
