import BuzzKit
import SwiftUI

/// One sidebar row, Slack-style: the channel's glyph or the peer's avatar, the resolved
/// name, and — when unread messages address you — a red badge. One line, nothing else.
///
/// # Why there is no preview and no timestamp
///
/// Both were here until Part 6. A preview answers "what was said", which is a question
/// the conversation itself answers a tap later, and it costs a rich-text parse, a mention
/// resolver, and a second line of height on every row. A timestamp beside a name with no
/// message to time is a number with nothing to say. What is left is the pair of things a
/// navigation list is actually for: which room this is, and whether it wants you.
///
/// # Compact, not a card
///
/// The Phase-4 row was a glass card per channel, which turned a navigation list into a
/// stack of unrelated tiles. This row draws no background of its own: the list surface
/// owns one background and the rows sit on it, which is what lets the sections read as
/// one navigation surface.
///
/// # What the row does *not* do
///
/// It resolves nothing. The title, the mark, and the indicator all arrive pre-computed on
/// ``SidebarRow``, built once per snapshot. The only live value it reads is the presence
/// roster — read here rather than in the sidebar's body, so a heartbeat re-renders these
/// small views instead of re-deriving every section above them.
struct ChannelRowView: View {
    let row: SidebarRow
    /// The live presence roster. Read inside *this* body on purpose: see above.
    let presence: PresenceModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            Text(row.title)
                // The Slack cue, and now the only one for ordinary unread: an unread name
                // is heavier and at full strength, a read one is quiet. There is no
                // separate dot — the name *is* the indicator, which is what leaves the
                // badge to mean one thing only.
                //
                // The weight is chosen while the font is built rather than layered on with
                // `.fontWeight(_:)`: it is a value on Inter's `wght` axis, resolved as the
                // face is, and a trait applied over an already-resolved face is a separate
                // mechanism. Under the static family this shipped with first, that trait
                // came back regular with no error and every row here read as read.
                .font(.hive(.headline, weight: row.indicator.isUnread ? .semibold : .regular))
                .foregroundStyle(row.indicator.isUnread ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            SidebarUnreadBadge(indicator: row.indicator)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOnline ? "Online" : "")
    }

    /// A channel shows its glyph; a direct message shows who it is with, and whether
    /// they are online.
    ///
    /// The dot is on the faces and on nothing else. Presence is a fact about a *person*,
    /// and a channel's dot could only ever mean "somebody in here is online" — which in a
    /// workspace whose agents hold a heartbeat is every channel, all the time, so the
    /// list read as a column of green that distinguished nothing.
    /// The mark itself is ``ConversationMark``, shared with the Drafts screen. Only the
    /// dot and the unread tint are this list's own — see below.
    private var leading: some View {
        ConversationMark(
            conversation: row.conversation,
            size: Self.glyphSize,
            glyphTint: row.indicator.isUnread ? .primary : .secondary
        )
        // On the mark rather than only on the face: a channel has no peer, so
        // ``isOnline`` is false for one and this draws nothing.
        .overlay(alignment: .bottomTrailing) { presenceDot }
    }

    @ViewBuilder
    private var presenceDot: some View {
        if isOnline {
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color.hiveNight, lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }

    /// Whether this row's peer is online. Only a direct message has one; a channel is
    /// never "online", which is why nothing here folds in ``SidebarRow/members``.
    private var isOnline: Bool {
        guard let peer = row.conversation.peer else { return false }
        return presence.isOnline(peer)
    }

    /// A spoken summary that folds the indicator in, so VoiceOver announces "2 mentions"
    /// rather than leaving a badge unlabelled after `.combine` — and says "starred", which
    /// is otherwise carried only by which heading the row sits under.
    private var accessibilityLabel: String {
        var parts = [row.title]
        if row.conversation.kind == .channel, row.isPrivate { parts.append("private") }
        // The count on a group DM's tile is drawn, so `.combine` cannot reach it — and it
        // is the one thing on the row a list of names does not already say.
        if let people = Self.peopleDescription(row.conversation) { parts.append(people) }
        if row.isStarred { parts.append("starred") }
        if let description = row.indicator.accessibilityDescription { parts.append(description) }
        return parts.joined(separator: ", ")
    }

    /// `4 people` for a group direct message, `nil` for everything else — a channel's
    /// roster is not what its row is about, and a one-to-one's is two by definition.
    static func peopleDescription(_ conversation: ConversationIdentity) -> String? {
        guard conversation.kind == .group, conversation.memberCount > 0 else { return nil }
        return conversation.memberCount == 1 ? "1 person" : "\(conversation.memberCount) people"
    }

    /// The glyph/avatar edge. Small enough that a one-line row stays compact, large
    /// enough that a monogram is legible.
    private static let glyphSize: CGFloat = 30
}

// MARK: - Indicator

/// The unread badge: how many unread messages in this conversation are addressed to you.
///
/// In a channel that is the ones that mention you. In a DM it is all of them — a room of
/// two has nobody else to be talking to — so the badge means the same thing in both places
/// and ``UnreadIndicator`` is what decides which count answers it.
///
/// Nothing is drawn for a channel's ordinary unread — the bolded name already said so. A
/// badge that appeared for that too would be a badge meaning "something happened", and the
/// whole point of this one is that it means "something happened *to you*".
///
/// Red rather than the app tint, which is the one place this list departs from its own
/// palette on purpose: a red count on a conversation row is what Slack and every system
/// app on this phone use for "these are yours and you have not read them", and a badge
/// that reads as decoration is a badge people walk past.
private struct SidebarUnreadBadge: View {
    let indicator: UnreadIndicator

    var body: some View {
        if let text = indicator.badgeText {
            Text(text)
                .font(.hive(.caption2, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.red))
                .accessibilityHidden(true)
        }
    }
}
