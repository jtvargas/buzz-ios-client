import SwiftUI

/// A Slack-style day separator: a hairline across the conversation with the day's
/// label resting on it. Subtle enough to scroll past, distinct enough to find when
/// looking for "where does yesterday end".
struct DaySeparatorView: View {
    @Environment(\.relativeTimeTicker) private var ticker

    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            rule
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            rule
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isHeader)
    }

    /// `Today` has to become `Yesterday` when the day turns under a screen that
    /// stayed open, so the label reads the same shared clock the timestamps do.
    private var label: String {
        DaySeparatorLabel.label(for: date, now: ticker?.now ?? Date())
    }

    private var rule: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(height: 0.5)
    }
}
