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
    let row: TimelineRow
    /// Whether this message's author is present in the workspace (S-5 presence).
    var isAuthorOnline: Bool = false
    /// The surviving reaction groups for this row (S-2), own reaction highlighted.
    var reactions: [ReactionGroup] = []
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

                if !row.isDeleted {
                    ReactionChipsView(
                        groups: reactions,
                        onTap: onToggleReaction,
                        onReact: onReact
                    )
                }
                if row.hasThread, let onOpenThread {
                    RepliesButton(count: row.replyCount, action: onOpenThread)
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
        .contextMenu {
            menuItems
        } preview: {
            MessagePreview(row: row)
        }
    }

    /// The author's avatar with a presence badge — the downsampled artwork (or a
    /// monogram) and a green dot at its corner when the author is online. The badge
    /// carries the presence signal VoiceOver reads through the row's accessibility
    /// value, so the avatar itself stays decorative.
    private var avatar: some View {
        AvatarView(url: authorPictureURL, seed: row.pubkey, initial: authorInitial, size: 36)
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
        } else if let rich = row.richContent, !rich.isEmpty {
            // Kind-40002 rich content is CommonMark markdown: render it as laid-out
            // blocks (headings, lists, code, quotes), falling back per-block to plain
            // text. Absent on relays that do not implement it — the plain branch below.
            MessageContentView(markdown: rich)
        } else {
            Text(Self.rendered(row.content))
                .font(.body)
                .textSelection(.enabled)
        }
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

    /// Renders a plain (kind-9) message's content as inline markdown — bold, italic,
    /// code spans, and *safe* links — preserving newlines and falling back to the raw
    /// text when it is not valid markdown. Shares ``MessageContent/inline(_:)`` with the
    /// rich renderer, so link sanitisation (only http/https/mailto stay tappable)
    /// applies to every message, not only kind-40002 rich content.
    static func rendered(_ content: String) -> AttributedString {
        MessageContent.inline(content)
    }
}

/// A tight preview for the long-press menu: the author and message content sized to
/// their content. Supplying it makes the lift a compact rounded card instead of the
/// default full-width row snapshot, which read as a large square bubble.
private struct MessagePreview: View {
    let row: TimelineRow

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
                Text(TimelineRowView.rendered(row.content))
                    .font(.body)
            }
        }
        .padding(12)
        .frame(maxWidth: 320, alignment: .leading)
    }
}

/// The "N replies" affordance under a message that has a thread.
private struct RepliesButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.bubble.right")
                Text(count == 1 ? "1 reply" : "\(count) replies")
            }
            .font(.caption.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .accessibilityHint("Double tap to open the thread")
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
