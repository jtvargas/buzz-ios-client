import BuzzKit
import SwiftUI

/// One sidebar row, Slack-style: the channel's glyph or the peer's avatar, the resolved
/// name, and — when unread messages address you — a mention badge. One line, nothing
/// else.
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
                // `.fontWeight(_:)`, which is the one thing the app's typeface cannot
                // honour: Lato ships as static cuts, so a weight asked for by trait comes
                // back regular and every row in the sidebar would have read as read.
                .font(.hive(.subheadline, weight: row.indicator.isUnread ? .semibold : .regular))
                .foregroundStyle(row.indicator.isUnread ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            SidebarMentionBadge(indicator: row.indicator)
        }
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOnline ? "Online" : "")
    }

    /// A channel shows its glyph; a direct message shows who it is with.
    @ViewBuilder
    private var leading: some View {
        switch row.conversation.kind {
        case .channel:
            channelGlyph.overlay(alignment: .bottomTrailing) { presenceDot }
        case .direct, .agent:
            AvatarView(
                url: row.conversation.picture,
                seed: row.conversation.avatarSeed,
                monogram: row.conversation.initials,
                size: Self.glyphSize
            )
            .overlay(alignment: .bottomTrailing) { presenceDot }
        }
    }

    private var channelGlyph: some View {
        RoundedRectangle(cornerRadius: AvatarShape.roundedSquare.cornerRadius(for: Self.glyphSize))
            .fill(Color.secondary.opacity(0.12))
            .frame(width: Self.glyphSize, height: Self.glyphSize)
            .overlay {
                Image(systemName: row.isPrivate ? "lock.fill" : "number")
                    .font(.hiveSymbol(.subheadline, weight: .semibold))
                    .foregroundStyle(row.indicator.isUnread ? Color.primary : Color.secondary)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var presenceDot: some View {
        if isOnline {
            Circle()
                .fill(Color.green)
                .frame(width: 9, height: 9)
                .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 1.5))
                .accessibilityHidden(true)
        }
    }

    /// A direct message is online when its peer is; a channel when anyone in its roster
    /// is. One derivation, from the roster the shared directory already resolved.
    private var isOnline: Bool {
        if let peer = row.conversation.peer {
            return presence.isOnline(peer)
        }
        return !row.members.isDisjoint(with: presence.online)
    }

    /// A spoken summary that folds the indicator in, so VoiceOver announces "2 mentions"
    /// rather than leaving a badge unlabelled after `.combine` — and says "starred", which
    /// is otherwise carried only by which heading the row sits under.
    private var accessibilityLabel: String {
        var parts = [row.title]
        if row.conversation.kind == .channel, row.isPrivate { parts.append("private") }
        if row.isStarred { parts.append("starred") }
        if let description = row.indicator.accessibilityDescription { parts.append(description) }
        return parts.joined(separator: ", ")
    }

    /// The glyph/avatar edge. Small enough that a one-line row stays compact, large
    /// enough that a monogram is legible.
    private static let glyphSize: CGFloat = 30
}

// MARK: - Indicator

/// The mention badge: how many unread messages in this conversation are addressed to
/// you.
///
/// Nothing is drawn for ordinary unread — the bolded name already said so. A badge that
/// appeared for both would be a badge meaning "something happened", and the whole point
/// of this one is that it means "something happened *to you*".
///
/// Red rather than the app tint, which is the one place this list departs from its own
/// palette on purpose: a red count on a conversation row is what Slack and every system
/// app on this phone use for "these are yours and you have not read them", and a badge
/// that reads as decoration is a badge people walk past.
private struct SidebarMentionBadge: View {
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
