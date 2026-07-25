import BuzzKit
import SwiftUI

/// One timeline message: author, relative time, content (markdown with a plain
/// fallback, or a "message deleted" placeholder), and the delivery treatment —
/// `.pending` dimmed, `.failed` carrying a tap-to-retry strip, `.sent` plain.
///
/// A reply is rendered inline for the slice with a subtle "reply" affordance;
/// dedicated thread views are step 3. The timeline query only surfaces replies
/// here when their author broadcast them, so this never buries a threaded
/// conversation.
struct TimelineRowView: View {
    let row: TimelineRow
    /// Whether this message's author is present in the workspace (S-5 presence).
    var isAuthorOnline: Bool = false
    let onRetry: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            content
            if case let .failed(reason) = row.delivery {
                RetryStrip(reason: reason) { onRetry(row.id) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(row.delivery == .pending ? 0.5 : 1)
        .animation(.default, value: row.delivery)
        .animation(.default, value: isAuthorOnline)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 6) {
            PresenceDot(isOnline: isAuthorOnline)
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
            Text(Self.rendered(row.content))
                .font(.body)
                .textSelection(.enabled)
        }
    }

    /// Renders content as inline markdown, falling back to the raw text when it is
    /// not valid markdown. `.inlineOnlyPreservingWhitespace` keeps newlines and
    /// avoids block constructs the slice does not lay out; kind-40002 rich content
    /// is step 6.
    static func rendered(_ content: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        return (try? AttributedString(markdown: content, options: options))
            ?? AttributedString(content)
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
