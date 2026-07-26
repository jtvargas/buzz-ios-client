import SwiftUI

/// The numbers a message row and everything that has to line up with it agree on.
///
/// They live here rather than as literals in each view because three separate things
/// are measured against the avatar gutter — the row's own content column, a day
/// separator's label, and the gap the channel and the thread put between two messages —
/// and a gutter that is 42pt in one place and 46pt in another is exactly the drift the
/// day separators were introduced to make visible.
///
/// The values are the reference client's (`comb`'s `Sizing`/`Space` scale): a 34pt
/// avatar declared with `@ScaledMetric(relativeTo: .subheadline)` so the gutter grows
/// with the name beside it, an 8pt gap into the content column, 12pt between messages,
/// and 2pt of extra leading on the body. Deliberately *not* a card: no row background,
/// no border, no inset panel — the only thing separating two messages is space.
enum MessageRowMetrics {
    /// The avatar's point size at the default text size, and so the width the content
    /// column is indented by. Declare it in a view as
    /// `@ScaledMetric(relativeTo: .subheadline) var avatarSize: CGFloat = MessageRowMetrics.avatarSize`
    /// — the row and the day separator both do, which is what keeps them aligned at
    /// every Dynamic Type setting rather than only at the default one.
    static let avatarSize: CGFloat = 34

    /// Between the avatar and the content column. Fixed rather than scaled: the gutter
    /// grows with the avatar, and scaling the gap as well pushed the text off a narrow
    /// screen at the accessibility sizes.
    static let avatarGap: CGFloat = 8

    /// Between the name and the time beside it, and between the time and the reply
    /// glyph after it.
    static let headerGap: CGFloat = 8

    /// Between two messages. Applied as the message list's `LazyVStack` spacing, so it
    /// is one number for the channel, the thread, and anything else that renders
    /// ``ConversationItem``s — and so it is *not* also padding on the row, which would
    /// have made the row's own height depend on it.
    static let betweenMessages: CGFloat = 12

    /// Extra leading on the message body. Two points is the reference client's value
    /// and the reason a three-line message reads as prose rather than as a block.
    static let bodyLineSpacing: CGFloat = 2

    /// A reply-preview face under a threaded message, at the default text size. Scaled
    /// against `.caption`, the size of the reply count it sits beside.
    static let replyPreviewAvatarSize: CGFloat = 18

    /// How many faces the reply preview shows — and, passed to
    /// ``BuzzKit/BuzzEventStore/threadParticipants(for:limit:)``, how many the read is
    /// asked for. One number, so the query can never fetch a face the strip drops.
    static let replyPreviewAvatars = 4

    /// The presence dot's diameter for an avatar of `size`, and the ring that lifts it
    /// off the artwork behind it.
    ///
    /// Proportional rather than fixed: the avatar grows with Dynamic Type, and a dot
    /// pinned at 11pt slid toward the middle of a 50pt avatar at the accessibility
    /// sizes instead of staying on its corner.
    static func presenceBadge(for size: CGFloat) -> (diameter: CGFloat, ring: CGFloat) {
        let diameter = max(9, size * 0.32)
        return (diameter, max(1.5, diameter * 0.18))
    }
}

/// The pressed state for the small controls on a message — the avatar, the sender's
/// name, and the conversation header pill.
///
/// A dim rather than a fill or a scale: these sit directly on the conversation with no
/// background of their own, so anything that draws a shape on press would turn part of
/// a message into a button, which is the thing §3 rules out. Deliberately no
/// `sensoryFeedback`: the brief asks for visual feedback *without* haptics, and a tap
/// that buzzes on the way to a profile sheet competes with the sheet's own presentation.
///
/// `contentShape` is applied here so every adopter gets a hit area covering its whole
/// frame — a `Text` otherwise only accepts taps on its glyphs.
struct PressFeedbackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.55 : 1)
            // Scoped to this control's own press, never ambient: an animation reaching
            // the enclosing list would animate row insertion in a bottom-anchored
            // scroll view.
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
