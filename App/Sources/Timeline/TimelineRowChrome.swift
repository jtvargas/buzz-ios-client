import BuzzKit
import Foundation
import SwiftUI

/// The small views a message row hangs off itself — the "N replies" affordance and the
/// delivery strips. Split out of `TimelineRowView.swift` so that file is about the row's
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
            // Inside the label, where the private style this replaces applied it. Outside
            // the button it would inset the *wash* rather than the text, and the strip's
            // two ends would stay unlit while it is held.
            .padding(.horizontal, 8)
        }
        // The 8pt corner is the one this affordance has always washed in, kept rather than
        // taken up to the vocabulary's default so the strip does not change shape.
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: 8)))
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

/// The live counterpart to ``RetryStrip``: a media send still working above the
/// relay drain, shown only where the row's authored media makes that wait visible.
struct SendingStrip: View {
    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
            Text("Sending…")
                .font(.hive(.caption))
        }
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sending")
    }
}

/// The "not delivered" strip on a failed send: a retry action when the same send
/// can succeed, or a direction to delete a terminal failure.
struct RetryStrip: View {
    let reason: String?
    var isRetryable = true
    var isEnabled = true
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        if isRetryable {
            Button(action: onRetry) { content }
                .buttonStyle(.plain)
                .disabled(!isEnabled)
                .accessibilityHint("Double tap to retry sending")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(label)
                .font(.hive(.caption))
        }
        .foregroundStyle(.red)
    }

    private var label: String {
        if let reason, !reason.isEmpty {
            return isRetryable
                ? "Not delivered (\(reason)) — tap to retry"
                : "Not delivered (\(reason)) — delete to dismiss"
        }
        return isRetryable ? "Not delivered — tap to retry" : "Not delivered — delete to dismiss"
    }
}
