import BuzzKit
import SwiftUI

/// One compact Slack-style channel row: channel glyph, name, newest-message
/// preview, unread badge, and an unobtrusive roster-presence marker.
struct ChannelRowView: View {
    @Environment(\.channelNameMap) private var channelNameMap

    let channel: ChannelListRow
    var mentions: [MentionRef] = []
    var selfPubkey: String?
    var hasOnlineMember = false

    private var displayName: String {
        if let name = channel.name, !name.isEmpty { return name }
        return channel.id
    }

    var body: some View {
        HStack(spacing: 12) {
            channelGlyph

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(displayName)
                        // A channel with unread messages reads bolder — the Slack-style
                        // emphasis that pairs with the count pill.
                        .font(.headline)
                        .fontWeight(channel.hasUnread ? .bold : .regular)
                        .lineLimit(1)
                    if channel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Private")
                    }
                    Spacer(minLength: 4)
                    if channel.hasUnread {
                        UnreadBadge(count: channel.unreadCount)
                    }
                    if let date = channel.lastMessageDate {
                        Text(date, format: .relative(presentation: .numeric))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                preview
            }
        }
        .padding(12)
        .channelRowGlass()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(hasOnlineMember ? "Members online" : "")
    }

    private var channelGlyph: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.secondary.opacity(0.12))
            .frame(width: 38, height: 38)
            .overlay {
                Image(systemName: channel.isPrivate ? "lock.fill" : "number")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(channel.hasUnread ? Color.accentColor : Color.secondary)
            }
            .overlay(alignment: .bottomTrailing) {
                if hasOnlineMember {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                }
            }
            .accessibilityHidden(true)
    }

    /// A spoken summary that folds the unread count in, so VoiceOver announces
    /// "3 unread" rather than leaving the pill unlabelled after `.combine`.
    private var accessibilityLabel: String {
        var parts = [displayName]
        if channel.isPrivate { parts.append("private") }
        if channel.hasUnread { parts.append("\(channel.unreadCount) unread") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var preview: some View {
        if let snippet = channel.lastMessageSnippet, !snippet.isEmpty {
            HStack(spacing: 0) {
                if let author = channel.lastMessageAuthor, !author.isEmpty {
                    Text("\(shortAuthor(author)): ")
                }
                RichTextView(
                    text: snippet,
                    resolver: MessageMentionResolver(
                        mentions: mentions,
                        channels: channelNameMap,
                        selfPubkey: selfPubkey
                    ),
                    mode: .snippet
                )
            }
            .font(.subheadline)
            .foregroundStyle(channel.hasUnread ? .primary : .secondary)
            .lineLimit(1)
        } else {
            Text("No messages yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// A profile name is shown whole; a raw pubkey is shortened so a row reads as a
    /// name rather than a 64-character identifier.
    private func shortAuthor(_ author: String) -> String {
        author.count == 64 ? String(author.prefix(8)) : author
    }
}

private extension View {
    @ViewBuilder
    func channelRowGlass() -> some View {
        if #available(iOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
    }
}

/// A Slack-style unread count pill. Caps the shown number at 99+ so a very busy
/// channel never widens the row, and stays monochrome-tinted to sit quietly against
/// the Liquid Glass list.
private struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 99 ? "99+" : "\(count)")
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityHidden(true)
    }
}
