import BuzzKit
import SwiftUI

/// One saved message on the Later screen.
///
/// The layout is Slack's, because the owner asked for Slack's: a quiet first line saying
/// where this came from and when it is due, the message itself under it, and the two
/// actions across the bottom. Everything above the actions is one tap target that opens
/// the message — a row about a message that could not be opened would be a dead end.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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

    // MARK: - Metadata

    private var metadata: some View {
        HStack(spacing: 6) {
            if !channelName.isEmpty {
                Text(channelName)
                    .lineLimit(1)
                Text(verbatim: "•").foregroundStyle(.tertiary)
            }
            Text(dueLabel)
            Spacer(minLength: 8)
        }
        .font(.hive(.caption))
        .foregroundStyle(.secondary)
    }

    /// When the reminder fires, phrased relative to now — "In 3 hours", "In 25 minutes".
    ///
    /// Derived from the stored `not_before` rather than from the preset that was chosen.
    /// The preset is not in the payload (NIP-ER has no field for it, and inventing one
    /// would be a field the desktop client drops), and the remaining time is the more
    /// useful fact anyway: it is what the row is counting down to.
    private var dueLabel: String {
        guard let due = row.dueDate else { return finishedLabel }
        let interval = due.timeIntervalSinceNow
        guard interval > 0 else { return "Due now" }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = interval < 3600 ? [.minute] : [.day, .hour]
        formatter.maximumUnitCount = 1
        guard let spelled = formatter.string(from: interval) else { return "Due soon" }
        return "In \(spelled)"
    }

    private var finishedLabel: String {
        switch row.status {
        case .done: "Completed"
        case .cancelled: "Archived"
        case .pending: "Due soon"
        }
    }

    // MARK: - Message

    private var message: some View {
        HStack(alignment: .top, spacing: 10) {
            AvatarView(
                url: authorPicture,
                seed: row.target?.authorPubkey ?? row.id,
                monogram: authorInitials,
                size: 36
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(authorName.isEmpty ? "Unknown" : authorName)
                    .font(.hive(.subheadline, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                Text(row.target?.preview ?? row.note ?? "")
                    .font(.hive(.subheadline))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 10) {
            Button(action: complete) {
                Text("Complete")
                    .font(.hive(.subheadline, weight: .semibold))
                    .padding(.horizontal, 20)
                    .frame(minHeight: 40)
            }
            .buttonStyle(.glassProminent)
            .accessibilityLabel("Complete reminder")

            Button(action: reschedule) {
                Image(systemName: "clock.badge")
                    .font(.hiveSymbol(.subheadline, weight: .semibold))
                    .frame(width: 44, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.glass)
            .accessibilityLabel("Change reminder time")

            Spacer(minLength: 0)
        }
        // Clear of the avatar column, so the two controls line up under the message rather
        // than under the face.
        .padding(.leading, 46)
    }
}
