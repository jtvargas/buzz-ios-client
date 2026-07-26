import BuzzKit
import SwiftUI
import UIKit

/// One timeline message: author, relative time, content (markdown with a plain
/// fallback, or a "message deleted" placeholder), reaction chips, a "N replies"
/// affordance, and the delivery treatment — `.pending` dimmed, `.failed` carrying a
/// tap-to-retry strip, `.sent` plain.
///
/// A long-press menu offers a quick-reaction palette and Copy, plus Retry/Delete on
/// an own pending or failed row. The same row renders in the channel timeline and
/// inside a thread; `onOpenThread` is supplied only in the channel, where a threaded
/// message can be opened, and omitted inside the thread it already shows.
struct TimelineRowView: View {
    @Environment(\.channelNameMap) private var channelNameMap
    @Environment(\.openURL) private var openURL
    @State private var suppressNextRowTap = false

    let row: TimelineRow
    /// Whether this message's author is present in the workspace (S-5 presence).
    var isAuthorOnline: Bool = false
    /// The surviving reaction groups for this row (S-2), own reaction highlighted.
    var reactions: [ReactionGroup] = []
    /// The users this message mentions, resolved to names from its own `p` tags —
    /// so a mention renders identically wherever the row appears (WS-1 #9).
    var mentions: [MentionRef] = []
    /// The local identity's hex pubkey, for self-mention emphasis. `nil` degrades to
    /// no self-emphasis (keyless fallback).
    var selfPubkey: String?
    /// Whether this is the local identity's own send, gating Delete/Retry in the menu.
    var isOwn: Bool = false
    let onRetry: (String) -> Void
    /// Send a fresh reaction with this emoji.
    var onReact: (String) -> Void = { _ in }
    /// Toggle an existing chip (add, or withdraw an own reaction).
    var onToggleReaction: (ReactionGroup) -> Void = { _ in }
    /// Discard this own pending/failed row.
    var onDelete: (String) -> Void = { _ in }
    /// Open this message's thread; absent when already inside a thread.
    var onOpenThread: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    header
                    content
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(accessibilityStatus)

                if !row.isDeleted, !reactions.isEmpty {
                    ReactionChipsView(
                        groups: reactions,
                        onTap: { group in
                            performControlAction { onToggleReaction(group) }
                        },
                        onReact: { emoji in
                            performControlAction { onReact(emoji) }
                        }
                    )
                }
                if row.hasThread, let onOpenThread {
                    RepliesButton(
                        count: row.replyCount,
                        lastReplyAt: row.lastReplyDate,
                        action: {
                            performControlAction(onOpenThread)
                        }
                    )
                }
                if case let .failed(reason) = row.delivery {
                    RetryStrip(reason: reason) { onRetry(row.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.delivery == .pending ? 0.5 : 1)
        .animation(.default, value: row.delivery)
        .animation(.default, value: isAuthorOnline)
        .contentShape(.rect)
        .onTapGesture {
            scheduleRowTap()
        }
        // AttributedString links are controls inside the otherwise tappable row.
        // Mark their gesture before handing the URL back to the app environment so
        // opening a link never also pushes the message's thread.
        .environment(\.openURL, OpenURLAction { url in
            suppressRowTapBriefly()
            openURL(url)
            return .handled
        })
        .accessibilityAction(named: "Open thread") {
            onOpenThread?()
        }
        .contextMenu {
            menuItems
        } preview: {
            MessagePreview(row: row, bodyText: bodyText, resolver: resolver)
        }
    }

    private func scheduleRowTap() {
        guard !row.isDeleted, let onOpenThread else { return }
        DispatchQueue.main.async {
            guard !suppressNextRowTap else { return }
            onOpenThread()
        }
    }

    private func performControlAction(_ action: () -> Void) {
        suppressRowTapBriefly()
        action()
    }

    private func suppressRowTapBriefly() {
        suppressNextRowTap = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            suppressNextRowTap = false
        }
    }

    /// The author's avatar with a presence badge — the downsampled artwork (or a
    /// monogram) and a green dot at its corner when the author is online. The badge
    /// carries the presence signal VoiceOver reads through the row's accessibility
    /// value, so the avatar itself stays decorative.
    private var avatar: some View {
        AvatarView(url: authorPictureURL, seed: row.pubkey, monogram: authorInitial, size: 36)
            .overlay(alignment: .bottomTrailing) {
                if isAuthorOnline {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 11, height: 11)
                        .overlay(Circle().strokeBorder(Color(.systemBackground), lineWidth: 2))
                }
            }
    }

    private var authorPictureURL: URL? {
        guard let picture = row.authorPicture, !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    private var authorInitial: String {
        row.displayName.first.map { String($0).uppercased() } ?? "#"
    }

    /// The status VoiceOver announces after the message: presence, whether it was
    /// edited, and its delivery state. Pure and testable via ``MessageAccessibility``.
    private var accessibilityStatus: String {
        MessageAccessibility.status(isOnline: isAuthorOnline, isEdited: row.isEdited, delivery: row.delivery)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(row.displayName)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if row.isReply {
                Image(systemName: "arrowshape.turn.up.left")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Reply")
            }
            Spacer(minLength: 4)
            Text(row.date, format: .relative(presentation: .numeric))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var content: some View {
        if row.isDeleted {
            Text("message deleted")
                .font(.body)
                .italic()
                .foregroundStyle(.secondary)
        } else {
            // One engine for both kind-40002 rich markdown and plain kind-9 content:
            // block layout, safe links, and resolved @mention / #channel tokens, so a
            // message renders identically on every surface (WS-1 #7/#9).
            RichTextView(text: bodyText, resolver: resolver)
        }
    }

    /// The content to render: the kind-40002 rich markdown when present, otherwise
    /// the plain kind-9 body. Both flow through the same engine.
    private var bodyText: String {
        if let rich = row.richContent, !rich.isEmpty { return rich }
        return row.content
    }

    /// The per-message resolver: mentions from this row's own `p`-tag refs, channels
    /// from the app-wide injected map, self from the local identity.
    private var resolver: MessageMentionResolver {
        MessageMentionResolver(mentions: mentions, channels: channelNameMap, selfPubkey: selfPubkey)
    }

    /// The long-press menu: a quick-reaction palette and Copy on any live message,
    /// plus Retry (on a failed send) and Delete on an own pending/failed row.
    @ViewBuilder
    private var menuItems: some View {
        if !row.isDeleted {
            ControlGroup {
                ForEach(ReactionPalette.common, id: \.self) { emoji in
                    Button(emoji) { onReact(emoji) }
                }
            }
            Button {
                UIPasteboard.general.string = row.content
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
        if isOwn, row.delivery != .sent {
            if case .failed = row.delivery {
                Button {
                    onRetry(row.id)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
            }
            Button(role: .destructive) {
                onDelete(row.id)
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

/// A tight preview for the long-press menu: the author and message content sized to
/// their content. Supplying it makes the lift a compact rounded card instead of the
/// default full-width row snapshot, which read as a large square bubble.
private struct MessagePreview: View {
    let row: TimelineRow
    let bodyText: String
    let resolver: MessageMentionResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.displayName)
                .font(.subheadline.weight(.semibold))
            if row.isDeleted {
                Text("message deleted")
                    .font(.body)
                    .italic()
                    .foregroundStyle(.secondary)
            } else {
                RichTextView(text: bodyText, resolver: resolver)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

/// The "N replies" affordance under a message that has a thread.
private struct RepliesButton: View {
    let count: Int
    let lastReplyAt: Date?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(count == 1 ? "1 reply" : "\(count) replies")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                if let lastReplyAt {
                    Text(ThreadSummaryDateFormatter.label(for: lastReplyAt))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(ThreadSummaryButtonStyle())
        .accessibilityHint("Double tap to open the thread")
    }
}

/// Slack's compact relative-day timestamp used beside the reply count.
enum ThreadSummaryDateFormatter {
    static func label(
        for date: Date,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        let prefix: String
        if day == today {
            prefix = "Today"
        } else if day == calendar.date(byAdding: .day, value: -1, to: today) {
            prefix = "Yesterday"
        } else {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate("MMM d")
            prefix = formatter.string(from: date)
        }
        let timeFormatter = DateFormatter()
        timeFormatter.locale = locale
        timeFormatter.calendar = calendar
        timeFormatter.timeZone = calendar.timeZone
        timeFormatter.dateStyle = .none
        timeFormatter.timeStyle = .short
        let time = timeFormatter.string(from: date)
        return "\(prefix) at \(time)"
    }
}

private struct ThreadSummaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.12 : 0))
            )
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// The "not delivered" strip on a failed send: the reason when the relay gave one,
/// and a retry action that re-queues the message.
private struct RetryStrip: View {
    let reason: String?
    let onRetry: () -> Void

    var body: some View {
        Button(action: onRetry) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text(label)
                    .font(.caption)
            }
            .foregroundStyle(.red)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Double tap to retry sending")
    }

    private var label: String {
        if let reason, !reason.isEmpty {
            return "Not delivered (\(reason)) — tap to retry"
        }
        return "Not delivered — tap to retry"
    }
}
