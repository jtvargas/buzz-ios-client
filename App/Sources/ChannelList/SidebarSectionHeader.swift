import SwiftUI

/// One sidebar section heading: a tappable expand/collapse control with a rotating
/// chevron and a count (§8).
///
/// The whole header is the hit target, not the chevron — a 12-pt glyph is not a
/// control anyone can hit, so the row is given a 44-pt minimum height and its own
/// content shape. The chevron rotates rather than swapping glyphs so the state change
/// reads as one continuous motion with the rows appearing beneath it.
struct SidebarSectionHeader: View {
    let section: SidebarSection
    /// How many conversations the section holds. Shown beside the title so a collapsed
    /// section still says how much it is hiding.
    let count: Int
    @Binding var isExpanded: Bool

    var body: some View {
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
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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
