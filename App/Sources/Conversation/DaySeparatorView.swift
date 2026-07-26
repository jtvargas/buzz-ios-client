import SwiftUI

/// A Slack-style day separator: the day's name at the left of the conversation, with a
/// hairline running out from it to the trailing edge. Large enough to find when looking
/// for "where does yesterday end", quiet enough to scroll past.
///
/// # Why it is left-aligned to the *message column* and not to the screen
///
/// A centred label with a rule on each side — which this was — reads as an ornament and
/// puts the one piece of text that answers "which day am I in" nowhere near the text it
/// applies to. §5 asks for the label at the left, matching the message content, so it
/// starts on the same vertical line the message bodies do: past the avatar gutter, not
/// against the screen edge.
///
/// That alignment is derived, never a literal. The gutter is
/// ``MessageRowMetrics/avatarSize`` — declared here with the *same*
/// `@ScaledMetric(relativeTo: .subheadline)` the row uses — plus
/// ``MessageRowMetrics/avatarGap``. A hard-coded 42 would line up at the default text
/// size and drift at every other one.
struct DaySeparatorView: View {
    @Environment(\.relativeTimeTicker) private var ticker

    /// The message row's avatar gutter at this reader's text size. See the type comment:
    /// this is the whole reason the separator and the row stay aligned.
    @ScaledMetric(relativeTo: .subheadline)
    private var avatarSize: CGFloat = MessageRowMetrics.avatarSize

    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            // Bold at `.subheadline`, the weight and size of a sender's name: a day
            // boundary is a heading over the messages under it, so it should read at
            // least as strongly as the names inside it. The old `.caption` semibold in
            // secondary was quieter than the timestamps it was meant to organise.
            Text(label)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize()
            // One hairline, running out to the trailing edge — not a border, and not a
            // second rule on the leading side, which is what made the old separator
            // read as centred.
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
        }
        // Inside-out: the gutter first, then the screen inset the message rows also
        // carry, so the label starts exactly where message text does.
        .padding(.leading, avatarSize + MessageRowMetrics.avatarGap)
        .padding(.horizontal)
        // On top of the list's `MessageRowMetrics.betweenMessages` on each side, so a
        // boundary gets visibly more air than the gap between two messages.
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    /// `Today` has to become `Yesterday` when the day turns under a screen that
    /// stayed open, so the label reads the same shared clock the timestamps do.
    private var label: String {
        DaySeparatorLabel.label(for: date, now: ticker?.now ?? Date())
    }
}
