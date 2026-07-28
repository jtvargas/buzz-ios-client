import BuzzKit
import Foundation
import SwiftUI

/// The small views a message row hangs off itself — the "N replies" affordance and the
/// failed-send strip. Split out of `TimelineRowView.swift` so that file is about the row's
/// own hierarchy.
///
/// A third one used to live here: `MessagePreview`, the compact card the long-press context
/// menu lifted in place of the default full-width row snapshot. It is gone with the menu —
/// the actions are a sheet now, and a sheet lifts nothing.

/// The "N replies" affordance under a message that has a thread: who has answered,
/// then how many times, then when the last one landed.
///
/// # Why the faces are inside the button and not tappable themselves
///
/// §6 requires that pressing the reply area still opens the thread. Making each face
/// its own control would put four small buttons inside a larger one, and a tap landing
/// on a face would then open a profile from a strip whose whole meaning is "there is a
/// conversation in here". The faces are decoration on one target, and hidden from
/// VoiceOver: the count beside them already says how many people are in there, and four
/// names read aloud before it would bury the number.
struct RepliesButton: View {
    /// The one identity resolver, read here rather than passed down: a face in this
    /// strip must be the same picture and the same monogram the message row above it
    /// shows for the same person.
    @Environment(\.entityNames) private var names

    /// Scaled against `.caption` — the size of the count the faces sit beside — so the
    /// strip keeps its proportions at every text size.
    @ScaledMetric(relativeTo: .caption)
    private var avatarSize: CGFloat = MessageRowMetrics.replyPreviewAvatarSize

    let count: Int
    let lastReplyAt: Date?
    /// The distinct repliers, oldest reply first. Already unique and already capped by
    /// ``BuzzKit/BuzzEventStore/threadParticipants(for:limit:)``; the `prefix` below is a
    /// belt-and-braces guard, not the place the limit is decided.
    var participants: [String] = []
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if !participants.isEmpty { faces }
                Text(count == 1 ? "1 reply" : "\(count) replies")
                    .font(.hive(.caption, weight: .semibold))
                    .foregroundStyle(.tint)
                if let lastReplyAt {
                    Text(ThreadSummaryDateFormatter.label(for: lastReplyAt))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.hive(.caption))
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(ThreadSummaryButtonStyle())
        .accessibilityHint("Double tap to open the thread")
    }

    /// Up to four mini rounded squares — the same shape ``AvatarView`` gives a message
    /// row, at a quarter of the area, so the strip reads as the same people rather than
    /// as a different kind of thing.
    private var faces: some View {
        HStack(spacing: 3) {
            ForEach(participants.prefix(MessageRowMetrics.replyPreviewAvatars), id: \.self) { pubkey in
                AvatarView(
                    url: names.picture(for: pubkey),
                    seed: pubkey,
                    monogram: names.initials(for: pubkey),
                    size: avatarSize
                )
            }
        }
        .accessibilityHidden(true)
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
                    .font(.hive(.caption))
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
