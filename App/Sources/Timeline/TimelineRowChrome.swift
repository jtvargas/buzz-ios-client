import BuzzKit
import Foundation
import SwiftUI

/// The small views a message row hangs off itself — its long-press preview, the
/// "N replies" affordance, and the failed-send strip. Split out of
/// `TimelineRowView.swift` so that file is about the row's own hierarchy.

/// A tight preview for the long-press menu: the author and message content sized to
/// their content. Supplying it makes the lift a compact rounded card instead of the
/// default full-width row snapshot, which read as a large square bubble.
struct MessagePreview: View {
    let row: TimelineRow
    /// The already-resolved author name, passed in rather than re-resolved so the
    /// preview cannot name someone differently from the row it lifted off.
    let authorName: String
    let bodyText: String
    let resolver: MessageMentionResolver

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(authorName)
                .font(.subheadline.weight(.bold))
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
struct RepliesButton: View {
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
struct RetryStrip: View {
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
