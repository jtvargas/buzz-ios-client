import BuzzKit
import SwiftUI

/// One compact sidebar row (§8): the channel's glyph or the peer's avatar, the
/// resolved name, the newest-message preview, the message time, and an unread or
/// mention indicator.
///
/// # Compact, not a card
///
/// The Phase-4 row was a glass card per channel, which turned a navigation list into
/// a stack of unrelated tiles. This row draws no background of its own: the list
/// surface owns one background and the rows sit on it, which is what lets three
/// sections read as one navigation surface.
///
/// # What the row does *not* do
///
/// It resolves nothing. The title, the avatar, the author prefix, the indicator, and
/// the mention resolver all arrive pre-computed on ``SidebarRow``, built once per
/// snapshot. The only live values it reads are the shared clock (inside
/// ``MessageTimestampView``, a leaf) and the presence roster — both read here rather
/// than in the sidebar's body, so a tick or a heartbeat re-renders these small views
/// instead of re-deriving every section above them.
struct ChannelRowView: View {
    let row: SidebarRow
    /// The live presence roster. Read inside *this* body on purpose: see above.
    let presence: PresenceModel

    var body: some View {
        HStack(spacing: 10) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                topLine
                SidebarPreview(row: row)
            }
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isOnline ? "Online" : "")
    }

    /// Name and time. The time is a leaf view so the shared 15-second tick invalidates
    /// one `Text` and not the row.
    private var topLine: some View {
        HStack(spacing: 6) {
            Text(row.title)
                .font(.subheadline)
                // Unread emphasis, the Slack cue that pairs with the indicator.
                .fontWeight(row.indicator.isUnread ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let date = row.date {
                MessageTimestampView(date: date, font: .caption2)
            }
            SidebarUnreadIndicator(indicator: row.indicator)
        }
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(row.indicator.isUnread ? Color.accentColor : Color.secondary)
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

    /// A spoken summary that folds the indicator in, so VoiceOver announces "3 unread,
    /// mentions you" rather than leaving a dot or pill unlabelled after `.combine`.
    private var accessibilityLabel: String {
        var parts = [row.title]
        if row.conversation.kind == .channel, row.isPrivate { parts.append("private") }
        if let description = row.indicator.accessibilityDescription { parts.append(description) }
        return parts.joined(separator: ", ")
    }

    /// The glyph/avatar edge. Small enough that a two-line row stays near 44pt, large
    /// enough that a monogram is legible.
    private static let glyphSize: CGFloat = 34
}

// MARK: - Indicator

/// The unread affordance: a quiet dot for ordinary unread, a numeric pill when the
/// unread messages mention you. Two shapes rather than one badge in two colours, so
/// the difference survives a glance and a colour-blind reader.
private struct SidebarUnreadIndicator: View {
    let indicator: UnreadIndicator

    var body: some View {
        switch indicator {
        case .caughtUp:
            EmptyView()
        case .unread:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        case .mention:
            Text(indicator.badgeText ?? "")
                .font(.caption2.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityHidden(true)
        }
    }
}

// MARK: - Preview line

/// The row's second line: who spoke, and what they said, on one line.
///
/// The snippet goes through the app-wide parse/resolve memo (``RichMessageCache``) and
/// the app-wide entity styling (``RichTextStyle``), so a mention reads as a tinted
/// `@Name` here exactly as it does in the timeline — but at `.subheadline`, since
/// ``RichTextView``'s snippet mode fixes its own base font at `.body`, which is too
/// tall for a compact row. One `Text`, not an `HStack`, so the author prefix and the
/// message truncate as a single line.
private struct SidebarPreview: View {
    let row: SidebarRow

    var body: some View {
        Group {
            if let snippet = row.snippet {
                Text(prefix + styled(snippet))
            } else {
                Text("No messages yet")
            }
        }
        .font(.subheadline)
        .foregroundStyle(row.indicator.isUnread ? .primary : .secondary)
        .lineLimit(1)
        .truncationMode(.tail)
    }

    /// `Ada: ` — already human-readable, or empty when the author is unknown.
    private var prefix: AttributedString {
        guard let author = row.authorLabel else { return AttributedString() }
        return AttributedString("\(author): ")
    }

    private func styled(_ snippet: String) -> AttributedString {
        let message = RichMessageCache.message(for: snippet, resolver: row.previewResolver)
        return RichTextStyle.styled(message.flattenedInline(), base: .subheadline)
    }
}
