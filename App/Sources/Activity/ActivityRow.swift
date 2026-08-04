import BuzzKit
import SwiftUI

/// One conversation in the Activity list — **not** one message.
///
/// That distinction is the entire row. The Flutter client draws one row per event, so nine
/// replies from one agent in one thread become nine rows that all say "Mention Jarvis"; the
/// reader has to open all nine to discover they are the same conversation. This draws the
/// newest event and says how much is behind it, so nine replies cost one row and one glance.
///
/// # What it says, in the order it says it
///
/// 1. **What kind of thing this is** — the category chip, or the specific headline when the
///    kind has one ("Job failed" is worth more than "Agent").
/// 2. **Where it happened** — `#channel`, or the person for a direct message.
/// 3. **Who, and what they said** — the author's face and name, then the message.
///
/// Kind before place before person, because the first question anyone brings to this screen
/// is "is this something I have to do", and the answer must not be at the end of a line that
/// truncates.
struct ActivityRow: View {
    let entry: ActivityEntry
    /// How much here is unseen, passed in rather than read off ``entry``.
    ///
    /// The store counts against the channel's read frontier, which nothing advances for a
    /// thread — so `entry.unreadCount` alone never clears on a threaded row. The screen
    /// folds in this device's own thread marks before handing the number down; see
    /// ``ActivityView/unreadCount(for:)``. Taking it as a parameter rather than reaching for
    /// the marks here keeps one answer to "is this unread" for the row and the chip above it.
    let unreadCount: Int
    let onOpen: () -> Void

    /// Whether anything here is unseen — the bolded name, and the pill.
    private var isUnread: Bool { unreadCount > 0 }

    /// The gutter, matched to every message row in the app so a face here sits on the same
    /// vertical line as a face in a conversation. `@ScaledMetric` for the reason
    /// ``ThreadActivityRow`` gives: the gutter has to grow with the name beside it, not only
    /// at the default text size.
    @ScaledMetric(relativeTo: .subheadline)
    private var avatarSize: CGFloat = MessageRowMetrics.avatarSize

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: MessageRowMetrics.avatarGap) {
                AvatarView(
                    url: entry.latest.authorPicture.flatMap(URL.init(string:)),
                    seed: entry.latest.pubkey,
                    monogram: EntityNames.initials(from: entry.latest.authorName),
                    size: avatarSize
                )
                VStack(alignment: .leading, spacing: 4) {
                    headline
                    destination
                    body(of: entry.latest)
                }
                // Fills the row so the whole width is pressable, not just the text.
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Inside the button, deliberately. This spacing used to live entirely in the
            // cell's `listRowInsets` — outside the button — which put the content in the right
            // place and left the press wash nothing to draw in: `PressTreatment` fills the
            // button's own frame, and that frame was exactly the content, so the highlight
            // ended flush against the avatar and the text. Splitting it moves the wash out to
            // where it can be seen without moving the content at all. See ``ActivityRowMetrics``.
            .padding(.horizontal, ActivityRowMetrics.labelPaddingH)
            .padding(.vertical, ActivityRowMetrics.labelPaddingV)
            // After the padding, so the whole highlighted area is pressable rather than just
            // the glyphs it surrounds.
            .contentShape(.rect)
        }
        // A bare `Button` with `.hivePress`, and deliberately nothing that tracks the press
        // from touch-down: no `onPressingChanged`, no `@GestureState`, no zero-distance
        // drag. This app has twice shipped a list that would not scroll because a row stole
        // the touch from the scroll view, and this is a list of rows.
        .buttonStyle(.hivePress)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the conversation")
    }

    /// What kind of thing this is, and when it last moved.
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            categoryChip
            if isUnread {
                unreadPill
            }
            Spacer(minLength: 4)
            MessageTimestampView(
                date: Date(timeIntervalSince1970: TimeInterval(entry.latest.createdAt)),
                font: .hive(.caption2)
            )
        }
    }

    /// The chip. `ActivityKinds.headline(forKind:)` wins when it has an answer, because
    /// "Job failed" and "Approval requested" are the two things on this screen someone
    /// actually has to act on, and "Agent"/"Action" would flatten both into their bucket.
    private var categoryChip: some View {
        Text(ActivityKinds.headline(forKind: entry.latest.kind) ?? entry.category.label)
            .font(.hive(.caption2, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            // The system material, not a hand-tinted capsule: this is the same glass the
            // filter chips above the list are made of, so a chip in a row and a chip in the
            // rail read as the same kind of object.
            .glassEffect(.regular, in: .capsule)
    }

    /// How much here has not been seen. A count rather than a dot: the dot is already
    /// implied by the bolded name below, and on a grouped row the number is the thing worth
    /// knowing — "3 unread" and "40 unread" are different amounts of evening.
    private var unreadPill: some View {
        Text(unreadCount, format: .number)
            .font(.hive(.caption2, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: .capsule)
            .accessibilityLabel("\(unreadCount) unread")
    }

    /// Where this happened, and how much of it there is.
    private var destination: some View {
        HStack(spacing: 6) {
            if entry.rootID != nil {
                Image(systemName: ThreadView.threadSymbol)
                    .font(.hiveSymbol(.caption2))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.hive(.caption, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if entry.eventCount > 1 {
                // The count that makes this a conversation row. Only drawn when it
                // collapsed something — "+0 more" on every single-message row would be
                // noise on the commonest row there is.
                Text("+\(entry.eventCount - 1) more")
                    .font(.hive(.caption))
                    .foregroundStyle(.tertiary)
                    .layoutPriority(1)
            }
        }
    }

    /// The author and what they said, on one flowing block.
    ///
    /// The name is bolded only while something here is unread — the same signal the sidebar
    /// uses for a channel with new messages, so "bold means unread" means one thing
    /// everywhere in the app rather than two.
    private func body(of event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.authorName)
                .font(.hive(.subheadline, weight: isUnread ? .semibold : .medium))
                .lineLimit(1)
            Text(event.content)
                .font(.hive(.subheadline))
                .foregroundStyle(.secondary)
                // Two lines, tail-truncated. A preview is an identifier, not the message —
                // and an uncapped one lets a single 60 KB paste set the height of the row.
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
        }
    }

    /// `#channel`, or the person for a direct message.
    ///
    /// A DM is titled by its author rather than by `entry.channelName` because the relay
    /// names a DM channel something unhelpful ("Group DM (2)"), and the author is by
    /// construction the only other person in it — the feed read excludes your own messages,
    /// so whoever wrote the newest event in a DM is the person you are talking to.
    private var title: String {
        if entry.isDirectMessage { return entry.latest.authorName }
        return entry.channelName.isEmpty ? "Unknown channel" : "#\(entry.channelName)"
    }
}

// MARK: - Previews

private func previewEvent(
    _ name: String,
    _ content: String,
    kind: Int = 9,
    minutesAgo: Int = 7
) -> ActivityEvent {
    ActivityEvent(
        id: UUID().uuidString,
        pubkey: String(repeating: "a", count: 64),
        authorName: name,
        authorPicture: nil,
        kind: kind,
        content: content,
        createdAt: Int64(Date().timeIntervalSince1970) - Int64(minutesAgo * 60)
    )
}

private func previewEntry(
    category: ActivityCategory,
    categories: [ActivityCategory]? = nil,
    channel: String = "buzz-ios-client",
    isDM: Bool = false,
    event: ActivityEvent,
    eventCount: Int = 1,
    unreadCount: Int = 0,
    rootID: String? = nil
) -> ActivityEntry {
    ActivityEntry(
        id: UUID().uuidString,
        category: category,
        categories: categories ?? [category],
        channelID: "chan",
        channelName: channel,
        isDirectMessage: isDM,
        latest: event,
        eventCount: eventCount,
        unreadCount: unreadCount,
        rootID: rootID
    )
}

#Preview("Activity rows") {
    List {
        // An unread mention: bold name, count, and the chip that says why it is here.
        ActivityRow(
            entry: previewEntry(
                category: .mention,
                event: previewEvent("JT", "@Jarvis check latest mobile and desktop buzz official client"),
                unreadCount: 1
            ),
            unreadCount: 1
        ) {}
        // The row this whole screen exists for: one conversation, forty events behind it.
        ActivityRow(
            entry: previewEntry(
                category: .mention,
                categories: [.mention, .activity],
                event: previewEvent("Fizz", "Pushed the row view and the previews.", minutesAgo: 22),
                eventCount: 6,
                unreadCount: 4,
                rootID: "root"
            ),
            unreadCount: 4
        ) {}
        // An agent job report, wearing its specific headline rather than "Agent".
        ActivityRow(
            entry: previewEntry(
                category: .agentActivity,
                event: previewEvent(
                    "Bumble", "Build failed: 2 errors in ActivityRow.swift",
                    kind: 43006, minutesAgo: 95
                ),
                unreadCount: 1
            ),
            unreadCount: 1
        ) {}
        // A direct message: titled by the person, not by whatever the relay called the room.
        ActivityRow(
            entry: previewEntry(
                category: .activity,
                channel: "Group DM (2)",
                isDM: true,
                event: previewEvent("Duncan", "are you around for a few minutes?", minutesAgo: 3),
                eventCount: 3,
                unreadCount: 3
            ),
            unreadCount: 3
        ) {}
        // Fully read: no pill, no bold. Still listed — it happened.
        ActivityRow(
            entry: previewEntry(
                category: .needsAction,
                event: previewEvent(
                    "Sentry", "Approval requested for deploy to production",
                    kind: 46010, minutesAgo: 1440
                )
            ),
            unreadCount: 0
        ) {}
    }
    .listStyle(.plain)
}
