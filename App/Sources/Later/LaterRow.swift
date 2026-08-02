import BuzzKit
import SwiftUI

/// One saved message on the Later screen.
///
/// The layout is Slack's, because the owner asked for Slack's: a quiet first line saying
/// where this came from and when it is due, the day it was saved on the far end of that
/// line, the message itself under it, and the two actions across the bottom. Everything
/// above the actions is one tap target that opens the message — a row about a message that
/// could not be opened would be a dead end.
///
/// The three measurements that make it read as a message rather than as a form are the
/// ones every other message surface in the app already uses: ``MessageRowMetrics/avatarSize``,
/// ``MessageRowMetrics/avatarGap``, and the same gutter under the avatar that
/// ``ThreadActivityRow`` puts its **Reply** button on. The actions are that row's controls
/// too — `.glass` beside `.glassProminent` at `.controlSize(.small)` — with the corner
/// squared off from the default capsule, which is the owner's correction: the first build
/// drew them a third taller than Slack's and fully round.
struct LaterRow: View {
    let row: ReminderRow
    let channelName: String
    let authorName: String
    let authorPicture: URL?
    let authorInitials: String
    /// Whether this row is in the In Progress tab. The actions only make sense there —
    /// a completed reminder has nothing to complete.
    let isPending: Bool
    let open: () -> Void
    let complete: () -> Void
    let reschedule: () -> Void

    /// The content column's indent, declared here rather than reached out of another view
    /// for the reason ``ThreadActivityRow`` declares its own: `@ScaledMetric` resolves
    /// against the environment of the view holding it, so it grows with the name beside it
    /// rather than only at the default text size.
    @ScaledMetric(relativeTo: .subheadline)
    private var avatarSize: CGFloat = MessageRowMetrics.avatarSize

    var body: some View {
        VStack(alignment: .leading, spacing: Self.betweenParts) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 6) {
                    metadata
                    message
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.hivePress(.inline))

            if isPending {
                actions
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Between the message and the controls under it. The gap the app puts between two
    /// separate things in a conversation, rather than a number invented for this screen.
    private static let betweenParts: CGFloat = MessageRowMetrics.betweenMessages

    // MARK: - Metadata

    private var metadata: some View {
        HStack(spacing: 6) {
            if !channelName.isEmpty {
                Text(channelName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: "•")
                    .foregroundStyle(.tertiary)
            }
            ReminderDueLabelView(row: row)
            Spacer(minLength: 8)
            Text(DaySeparatorLabel.label(for: savedDate))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityLabel(Text("Saved \(savedDate, format: .dateTime.month().day())"))
        }
        .font(.hive(.caption))
        .foregroundStyle(.secondary)
    }

    /// The day this reminder was set, which is what the far end of the first line says.
    ///
    /// Slack puts the *message's* date there. A reminder does not carry one: its payload is
    /// the target's id, channel, author and preview, and a Nostr event id says nothing about
    /// when the event was written. The day it was saved is the fact this row actually holds,
    /// and for the case that matters — saving something you are reading now — it is the same
    /// day anyway.
    private var savedDate: Date {
        Date(timeIntervalSince1970: TimeInterval(row.createdAt))
    }

    // MARK: - Message

    private var message: some View {
        HStack(alignment: .top, spacing: MessageRowMetrics.avatarGap) {
            AvatarView(
                url: authorPicture,
                seed: row.target?.authorPubkey ?? row.id,
                monogram: authorInitials,
                size: avatarSize
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(authorName.isEmpty ? "Unknown" : authorName)
                    .font(.hive(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Text(row.target?.preview ?? row.note ?? "")
                    .font(.hive(.subheadline))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            .foregroundStyle(Color.primary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Complete", action: complete)
                .buttonStyle(.glassProminent)
                .accessibilityHint("Marks this reminder done, here and on desktop")

            Button(action: reschedule) {
                Image(systemName: "clock.badge")
                    .font(.hiveSymbol(.footnote, weight: .semibold))
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Change reminder time")

            Spacer(minLength: 0)
        }
        .font(.hive(.subheadline, weight: .semibold))
        .controlSize(.small)
        // Squared off. A capsule is the default under both glass styles and is what the
        // owner meant by "too rounded"; Slack's own pair sit at about this radius.
        .buttonBorderShape(.roundedRectangle(radius: Self.actionRadius))
        // Clear of the avatar column, so the two controls line up under the message rather
        // than under the face — the same gutter ``ThreadActivityRow`` puts **Reply** on.
        .padding(.leading, avatarSize + MessageRowMetrics.avatarGap)
    }

    /// The corner on both controls — see ``actions``.
    private static let actionRadius: CGFloat = 10
}
