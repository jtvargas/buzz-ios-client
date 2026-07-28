import SwiftUI

/// A Slack-style day separator: the day's name at the left of the conversation with a
/// hairline underneath it, running out to the trailing edge. Large enough to find when
/// looking for "where does yesterday end", quiet enough to scroll past.
///
/// # Where the label starts
///
/// On the *row's* leading edge — the vertical line an avatar starts on — and not on the
/// line message text starts on. Indenting it by the avatar gutter (which is what this
/// did) left the day hanging inside the conversation with every avatar outdented to its
/// left, so it read as another message rather than as a heading over the messages under
/// it. Slack aligns the boundary with the row, and so does this.
///
/// # Why the rule is under the label and not beside it
///
/// A label with a line running out from its side is a divider carrying a caption: the eye
/// reads the line as the boundary and the text as an annotation on it. Label over rule is
/// the other way round — the day is the heading, and the rule is its underline.
///
/// Every horizontal number comes from ``MessageRowMetrics`` and the vertical air from the
/// list's own inter-message spacing, so the separator cannot drift from the rows it
/// organises.
struct DaySeparatorView: View {
    @Environment(\.relativeTimeTicker) private var ticker

    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Self.labelToRule) {
            // Bold at `.subheadline`, the weight and size of a sender's name: a day
            // boundary is a heading over the messages under it, so it should read at
            // least as strongly as the names inside it. The old `.caption` semibold in
            // secondary was quieter than the timestamps it was meant to organise.
            //
            // No `fixedSize()`: with the rule below rather than beside it the label has
            // the whole row width, so a long localised date can wrap instead of being
            // pushed off a narrow screen at the accessibility text sizes.
            Text(label)
                .font(.hive(.subheadline, weight: .bold))
                .foregroundStyle(.primary)
            Rectangle()
                .fill(Color.secondary.opacity(0.25))
                .frame(height: 0.5)
        }
        // The same inset on both sides: the label starts where an avatar starts and the
        // rule ends where a message's content ends.
        .padding(.horizontal, Self.leadingInset)
        .padding(.vertical, Self.verticalAir)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    /// Where the label and its rule begin: the message row's own leading edge.
    ///
    /// Deliberately *not* `rowLeading + avatarSize + avatarGap`. That is the message
    /// *text* column, and a separator aligned to it is the reported defect — which is
    /// what the test asserts, since the alignment itself is not observable from a unit
    /// test.
    static var leadingInset: CGFloat { MessageRowMetrics.rowLeading }

    /// Between the label and its rule. Tighter than the air around the pair, so the two
    /// read as one heading.
    static var labelToRule: CGFloat { 4 }

    /// Above and below the pair, on top of the list's own
    /// ``MessageRowMetrics/betweenMessages`` — half of it on each side, so a day boundary
    /// gets one and a half times the air two ordinary messages get.
    static var verticalAir: CGFloat { MessageRowMetrics.betweenMessages / 2 }

    /// `Today` has to become `Yesterday` when the day turns under a screen that
    /// stayed open, so the label reads the same shared clock the timestamps do.
    private var label: String {
        DaySeparatorLabel.label(for: date, now: ticker?.now ?? Date())
    }
}
