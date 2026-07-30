import Foundation

/// Who posted a picture, when, and where — everything the full-screen viewer's header
/// names it with.
///
/// Resolved by the row that draws the picture rather than by the viewer, because the row
/// is the only thing that holds all three halves at once: the message gives the author and
/// the time, the shared directory gives that author their current name and face, and the
/// surface gives the conversation. The viewer is handed the answer.
///
/// It is optional the whole way down. A surface with no conversation to name — a preview,
/// a future gallery reached from somewhere other than a message — presents a viewer that
/// simply draws no header, rather than one that draws a header with holes in it.
struct MessageMediaAttribution: Equatable {
    /// The author's name as every other surface renders it, already resolved through the
    /// directory and already fallen back to a short identifier if nobody knows one.
    let authorName: String
    /// The author's artwork, when the directory or the message's own joined profile has
    /// one. `nil` draws the monogram instead, exactly as a message row does.
    let authorPictureURL: URL?
    /// Up to two initials, taken from the name actually shown so the two cannot disagree.
    let authorInitials: String
    /// What a monogram takes its tint from — the author's key, so one person keeps one
    /// colour here and in every row they appear in.
    let authorSeed: String
    /// When the message carrying the picture was sent.
    let sentAt: Date
    /// The conversation it was sent in, already named: a channel's name, or the person's
    /// for a direct message.
    let conversationTitle: String
    /// Whether that conversation is a direct message.
    ///
    /// Not cosmetic: a channel is named with a `#` and a person is not, and a *group* DM's
    /// title is a list of names (`Ana, Ben, Cal…`) that a `#` in front of would make
    /// nonsense of. The one flag decides both.
    let conversationIsDirect: Bool

    /// The second line: `in: #general`, or `in: Ana Ruiz` for a direct message.
    ///
    /// The `in:` is the owner's, from the Slack header he specified, and it is what makes
    /// the line a *place* rather than a second name.
    var placeLabel: String {
        conversationIsDirect ? "in: \(conversationTitle)" : "in: #\(conversationTitle)"
    }

    /// The hour the picture was sent — and the day as well, once that stops being today.
    ///
    /// A bare `5:18 PM` is exactly right for a picture from this afternoon and a small lie
    /// for one from March: nothing else on this screen says which day, where a message row
    /// has the day separator above it to lean on. Both halves are the conversation's own
    /// formatters, so the viewer cannot drift from the timeline it was opened from.
    func timeLabel(
        now: Date = Date(),
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let time = MessageTimestamp.time(for: sentAt, locale: locale, calendar: calendar)
        guard !calendar.isDate(sentAt, inSameDayAs: now) else { return time }
        let day = DaySeparatorLabel.label(for: sentAt, now: now, locale: locale, calendar: calendar)
        return "\(day) at \(time)"
    }

    /// The whole header as one utterance, for the reader who cannot see it.
    var accessibilityLabel: String {
        "\(authorName), \(timeLabel()), \(placeLabel)"
    }
}
