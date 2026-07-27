import SwiftUI

/// One sidebar section heading, Slack-style: a hairline rule, then a tappable
/// expand/collapse control with a rotating chevron.
///
/// The whole header is the hit target, not the chevron — a 12-pt glyph is not a
/// control anyone can hit, so the row is given a 44-pt minimum height and its own
/// content shape. The chevron rotates rather than swapping glyphs so the state change
/// reads as one continuous motion with the rows appearing beneath it.
///
/// # The count, and when it is worth showing
///
/// Only while the section is collapsed. Open, the rows are right there and the number
/// beside the heading is a second, worse way to count them; collapsed, it is the only
/// thing that says how much is hidden. The accessibility label carries it either way,
/// because a screen reader has no rows in view to count.
///
/// # The rule above it
///
/// The divider belongs to the header rather than sitting between rows: a per-row rule
/// makes a list of conversations read as a form, where one rule per heading separates the
/// groups and nothing else. Every heading draws one, including the first — the home
/// shortcuts always sit above it, so there is always a group up there to be separated
/// from.
struct SidebarSectionHeader: View {
    let section: SidebarSection
    /// How many conversations the section holds.
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .accessibilityHidden(true)
            control
        }
    }

    private var control: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.22), value: isExpanded)
                    .frame(width: 12)
                Text(section.title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                if !isExpanded {
                    Text("\(count)")
                        .font(.caption2.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            // A section heading is a control, so it carries a full-height target even
            // though its text is small.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // List section headers upper-case their text by default; the spec's headings
        // are title-case.
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
    }
}
