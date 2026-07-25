import BuzzKit
import SwiftUI

/// One channel-list row: picture, name, and the newest message's author + snippet
/// with a relative timestamp.
struct ChannelRowView: View {
    let channel: ChannelListRow

    private var displayName: String {
        if let name = channel.name, !name.isEmpty { return name }
        return channel.id
    }

    var body: some View {
        HStack(spacing: 12) {
            ChannelAvatar(pictureURL: channel.picture, seed: channel.id)

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
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(channel.hasUnread ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    /// A spoken summary that folds the unread count in, so VoiceOver announces
    /// "3 unread" rather than leaving the pill unlabelled after `.combine`.
    private var accessibilityLabel: String {
        var parts = [displayName]
        if channel.isPrivate { parts.append("private") }
        if channel.hasUnread { parts.append("\(channel.unreadCount) unread") }
        return parts.joined(separator: ", ")
    }

    private var previewText: String {
        guard let snippet = channel.lastMessageSnippet, !snippet.isEmpty else {
            return "No messages yet"
        }
        if let author = channel.lastMessageAuthor, !author.isEmpty {
            return "\(shortAuthor(author)): \(snippet)"
        }
        return snippet
    }

    /// A profile name is shown whole; a raw pubkey is shortened so a row reads as a
    /// name rather than a 64-character identifier.
    private func shortAuthor(_ author: String) -> String {
        author.count == 64 ? String(author.prefix(8)) : author
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

/// The channel picture, falling back to a monogram tinted from the channel id so
/// every channel has a stable, distinct avatar even without artwork.
private struct ChannelAvatar: View {
    let pictureURL: String?
    let seed: String

    private var url: URL? {
        guard let pictureURL, !pictureURL.isEmpty else { return nil }
        return URL(string: pictureURL)
    }

    var body: some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case let .success(image):
                image.resizable().scaledToFill()
            default:
                monogram
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(.circle)
    }

    private var monogram: some View {
        Circle()
            .fill(Color(hue: hue, saturation: 0.5, brightness: 0.8).gradient)
            .overlay {
                Text(initial)
                    .font(.headline)
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        seed.first.map { String($0).uppercased() } ?? "#"
    }

    /// A stable hue from the channel id — a byte sum rather than `hashValue`, which
    /// is randomised per launch and would flicker a channel's colour between runs.
    private var hue: Double {
        let sum = seed.utf8.reduce(0) { $0 &+ Int($1) }
        return Double(sum % 360) / 360
    }
}
