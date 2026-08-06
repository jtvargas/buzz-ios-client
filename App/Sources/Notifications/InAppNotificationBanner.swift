import SwiftUI

/// The foreground-only banner: a native control with the same material, typography and
/// identity treatment as the rest of Hive.
struct InAppNotificationBanner: View {
    let notification: InAppNotification
    let open: () -> Void
    let dismiss: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40
    @GestureState private var verticalDrag: CGFloat = 0

    private static let cornerRadius: CGFloat = 22

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 11) {
                AvatarView(
                    url: notification.entry.latest.authorPicture.flatMap(URL.init(string:)),
                    seed: notification.entry.latest.pubkey,
                    monogram: EntityNames.initials(from: notification.entry.latest.authorName),
                    size: avatarSize
                )

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(notification.entry.latest.authorName)
                            .font(.hive(.subheadline, weight: .semibold))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text("now")
                            .font(.hive(.caption2))
                            .foregroundStyle(.secondary)
                    }
                    Text(notification.context)
                        .font(.hive(.caption, weight: .medium))
                        .foregroundStyle(Color.hiveAccent)
                        .lineLimit(1)
                    Text(notification.entry.latest.content)
                        .font(.hive(.subheadline))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .contentShape(.rect(cornerRadius: Self.cornerRadius))
        }
        .buttonStyle(.hivePress(.control, in: .rect(cornerRadius: Self.cornerRadius)))
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: Self.cornerRadius))
        .shadow(color: .black.opacity(0.28), radius: 16, y: 8)
        .offset(y: verticalDrag)
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .updating($verticalDrag) { value, state, _ in
                    state = min(0, value.translation.height)
                }
                .onEnded { value in
                    if value.translation.height < -24 { dismiss() }
                }
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notification.accessibilityLabel)
        .accessibilityHint("Opens the conversation. Swipe up to dismiss.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Dismiss") { dismiss() }
    }
}
