import SwiftUI

/// The foreground-only banner: a native control with the same material, typography and
/// identity treatment as the rest of Hive.
///
/// # Reading as a notification
///
/// The order of the three lines is the whole difference between this and a card. iOS puts the
/// **source** on top — small, secondary, beside the time — then the title, then the body, and
/// a reader recognises that shape long before they read a word of it. This drew the source
/// *below* the sender in accent colour until 2026-08-09, which is why it read as one of the
/// app's own cards that happened to be floating.
struct InAppNotificationBanner: View {
    let notification: InAppNotification
    let open: () -> Void
    let dismiss: () -> Void

    @ScaledMetric(relativeTo: .body) private var avatarSize: CGFloat = 40
    @GestureState private var verticalDrag: CGFloat = 0

    private static let cornerRadius: CGFloat = 26

    /// Computed rather than stored: a `Shape` is a `View`, and a stored static of one is a
    /// concurrency-safety question this has no reason to answer.
    private static var shape: RoundedRectangle {
        .rect(cornerRadius: cornerRadius, style: .continuous)
    }

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
                        Text(notification.context)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(BannerTimeLabel.label(for: notification.entry.latest.createdAt))
                    }
                    .font(.hive(.caption2))
                    .foregroundStyle(.secondary)

                    Text(notification.entry.latest.authorName)
                        .font(.hive(.subheadline, weight: .semibold))
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
            .contentShape(Self.shape)
        }
        .buttonStyle(.hivePress(.control, in: Self.shape))
        .glassEffect(.regular.interactive(), in: Self.shape)
        // The lit edge is what makes glass read as glass rather than as a grey rectangle:
        // brightest along the top where a light above it would catch, gone by the bottom.
        // `strokeBorder` and not `stroke`, so the hairline sits inside the corner instead of
        // straddling it. Hit testing off — a half-point ring drawn over the card's own edge
        // is otherwise a target that can swallow a tap meant for the button underneath.
        .overlay(Self.shape.strokeBorder(Self.edge, lineWidth: 0.5).allowsHitTesting(false))
        // Wider and fainter than it was (0.28/16/y8). At the very top of the screen a tight
        // dark shadow reads as a cut-out pasted on; the system's own banner casts a large
        // soft one that only says "this is above everything".
        .shadow(color: .black.opacity(0.22), radius: 24, y: 10)
        .offset(y: verticalDrag)
        // `highPriorityGesture`, **not** `simultaneousGesture`. Simultaneous means both
        // recognisers are allowed to win, and a 24pt swipe still ends inside this ~70pt card
        // — so a swipe-to-dismiss fired `dismiss` *and* `open`, and the reader landed in the
        // conversation they had just flicked away. High priority lets the drag pre-empt the
        // button the moment it starts travelling; a tap never travels 8pt, so tap-to-open is
        // untouched. Measured both ways on a driven simulator before it was changed.
        .highPriorityGesture(
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

    private static var edge: LinearGradient {
        LinearGradient(
            colors: [.white.opacity(0.24), .white.opacity(0.04)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// The time on the banner's source line.
///
/// Static on purpose — there is no timer behind it and there should not be one. A banner is
/// on screen for five seconds and is drawn the instant its message arrives, so in practice
/// this says `now` and the later branches exist for the case the feed hands back something
/// that has been sitting unread: a banner claiming `now` about an hour-old message is the
/// only way this can lie.
enum BannerTimeLabel {
    /// - Parameter createdAt: Unix seconds, as ``ActivityEvent`` carries it.
    static func label(
        for createdAt: Int64,
        relativeTo now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        // Negative elapsed is a real case, not a defensive one: `createdAt` is the *author's*
        // clock, and a device a few seconds ahead of ours would otherwise round to "0m ago".
        let elapsed = now.timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(createdAt)))
        if elapsed < 60 { return "now" }
        if elapsed < 3600 { return "\(Int(elapsed / 60))m ago" }
        if elapsed < 86_400 { return "\(Int(elapsed / 3600))h ago" }

        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(createdAt)))
    }
}
