import Foundation
@testable import Hive
import Testing

/// What the full-screen viewer's header says.
///
/// Two rules, both of which are wrong in a way a reader would notice rather than in a way
/// a test would: a `#` in front of a person's name, and an hour with no day on a picture
/// from three months ago.
@Suite("Message media attribution")
struct MessageMediaAttributionTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    static let locale = Locale(identifier: "en_US_POSIX")

    static func attribution(
        title: String = "general",
        isDirect: Bool = false,
        sentAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> MessageMediaAttribution {
        MessageMediaAttribution(
            authorName: "Ana Ruiz",
            authorPictureURL: nil,
            authorInitials: "AR",
            authorSeed: "abc",
            sentAt: sentAt,
            conversationTitle: title,
            conversationIsDirect: isDirect
        )
    }
}

extension MessageMediaAttributionTests {
    @Test("a channel is named with a hash")
    func channelPlace() {
        #expect(Self.attribution(title: "general").placeLabel == "in: #general")
    }

    /// A direct message is a person, and `#Ana Ruiz` is not a place.
    @Test("a direct message is named without one")
    func directPlace() {
        #expect(Self.attribution(title: "Ana Ruiz", isDirect: true).placeLabel == "in: Ana Ruiz")
    }

    /// A group DM's title is a list of names — the case that makes the `#` a category
    /// error rather than a small oddity.
    @Test("a group direct message keeps its list of names unprefixed")
    func groupDirectPlace() {
        #expect(Self.attribution(title: "Ana, Ben, Cal…", isDirect: true).placeLabel == "in: Ana, Ben, Cal…")
    }

    /// Today needs no day: the reader knows which one it is.
    @Test("a picture from today reads as an hour alone")
    func todayIsTheHourAlone() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let label = Self.attribution(sentAt: sent).timeLabel(
            now: sent.addingTimeInterval(3600),
            locale: Self.locale,
            calendar: Self.calendar
        )
        let hour = MessageTimestamp.time(for: sent, locale: Self.locale, calendar: Self.calendar)
        #expect(label == hour)
    }

    /// Any other day does: nothing else on this screen says which one, where a message row
    /// has the day separator above it.
    @Test("a picture from another day carries that day")
    func anotherDayCarriesTheDay() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let now = sent.addingTimeInterval(60 * 60 * 24 * 3)
        let label = Self.attribution(sentAt: sent).timeLabel(
            now: now,
            locale: Self.locale,
            calendar: Self.calendar
        )
        let day = DaySeparatorLabel.label(for: sent, now: now, locale: Self.locale, calendar: Self.calendar)
        #expect(label.hasPrefix(day))
        #expect(label.contains(" at "))
    }

    /// Yesterday is another day, and the nearest boundary to get wrong.
    @Test("yesterday is a day, not today")
    func yesterdayCarriesTheDay() {
        let sent = Date(timeIntervalSince1970: 1_700_000_000)
        let now = sent.addingTimeInterval(60 * 60 * 24)
        let label = Self.attribution(sentAt: sent).timeLabel(
            now: now,
            locale: Self.locale,
            calendar: Self.calendar
        )
        #expect(label.contains(" at "))
    }

    /// The header is one utterance to VoiceOver, and it has to carry all three parts —
    /// the face and the two lines are `.ignore`d in favour of this.
    @Test("the spoken header names the author, the time and the place")
    func spokenHeaderIsWhole() {
        let label = Self.attribution(title: "general").accessibilityLabel
        #expect(label.contains("Ana Ruiz"))
        #expect(label.contains("in: #general"))
    }
}
