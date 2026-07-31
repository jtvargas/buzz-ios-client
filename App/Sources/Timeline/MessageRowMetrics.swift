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
    /// The screen inset a message row carries, and so the vertical line an avatar's
    /// leading edge sits on.
    ///
    /// A constant rather than a bare `.padding(.horizontal)` in each view because four
    /// things have to start on that line — the row, a day separator's label, the
    /// conversation header's pill, and the rule under the thread opener — and SwiftUI's
    /// default padding agreeing in four files is an accident waiting to be changed in
    /// one of them.
    static let rowLeading: CGFloat = 16

    /// The avatar's point size at the default text size, and so the width the content
    /// column is indented by. Declare it in a view as
    /// `@ScaledMetric(relativeTo: .subheadline) var avatarSize: CGFloat = MessageRowMetrics.avatarSize`
    /// so the gutter grows with the name beside it rather than only at the default text
    /// size.
    static let avatarSize: CGFloat = 34

    /// Between the avatar and the content column. Fixed rather than scaled: the gutter
    /// grows with the avatar, and scaling the gap as well pushed the text off a narrow
    /// screen at the accessibility sizes.
    static let avatarGap: CGFloat = 8

    /// Between the name and the time beside it, and between the time and the reply
    /// glyph after it.
    static let headerGap: CGFloat = 8

    /// Between two messages that are not part of one block — and between a message and
    /// the furniture around it, a day separator or a relay notice.
    ///
    /// One number for the channel, the thread, and anything else that renders
    /// ``ConversationItem``s. It is *not* padding on the row: a row's own height stays
    /// its content's height, and the space around it belongs to the list.
    static let betweenMessages: CGFloat = 12

    /// Between two messages by one author inside a block — the run
    /// ``ConversationGrouping`` marks with `continuesGroup`.
    ///
    /// Half the gap between blocks, which is what makes a block read as one thing said in
    /// one breath rather than as three remarks that happen to share a face. It is not
    /// tighter than that on purpose: ``bodyLineSpacing`` puts 2pt between two lines of one
    /// message, so a gap much under this would leave a run of one-line replies reading as
    /// a single wrapped paragraph — the mistake in the other direction, and the harder one
    /// to see in a screenshot.
    static let withinGroup: CGFloat = 6

    /// What an item that *starts* something — a new block, a day, a notice — adds on top
    /// of the list's own ``withinGroup`` rhythm to make the full ``betweenMessages`` gap.
    ///
    /// The list is spaced at ``withinGroup`` and each such item pads its own top by this,
    /// rather than the reverse (spacing at ``betweenMessages`` and a continuation pulling
    /// itself up by a negative padding): the space above an item is then something an item
    /// declares, and nothing in the layout is ever asked to occupy less room than it takes.
    static var aboveNewGroup: CGFloat { betweenMessages - withinGroup }

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

    /// How far a pressed message's highlight bleeds past the row, vertically. The
    /// horizontal bleed is ``rowLeading`` — the inset the surface applies — so the
    /// highlight reaches both screen edges the way a list row's does.
    ///
    /// Half ``withinGroup``, so a pressed message inside a block lights up without its
    /// highlight touching the message stacked under it.
    static let pressBleed: CGFloat = 3
}
