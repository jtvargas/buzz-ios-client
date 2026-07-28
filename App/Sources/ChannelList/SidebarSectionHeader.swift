import SwiftUI

/// One sidebar heading, Slack-style: a hairline rule, then a tappable expand/collapse
/// control with a rotating chevron.
///
/// The whole header is the hit target, not the chevron — a 12-pt glyph is not a control
/// anyone can hit, so the row is given a 44-pt minimum height and its own content shape.
/// The chevron rotates rather than swapping glyphs so the state change reads as one
/// continuous motion with the rows appearing beneath it.
///
/// # Why this is an ordinary row and not a `Section` header
///
/// Because a `Section` header under `.plain` **pins**: it detaches from its group and rides
/// the top of the viewport while that group scrolls under it, so the heading on screen is
/// frequently one the rows below it do not belong to. Stickiness is not something this view
/// can opt out of — it is what the list style does to a header — so the sidebar is one flat
/// list and a heading is a row in it (see ``ChannelListView``). The rule above it makes the
/// grouping, and it scrolls away with the rows it introduces.
///
/// # The type it is set in
///
/// A heading is a landmark, so it is set like one: `.title3`, bold, at full strength. The
/// footnote-sized grey it replaces was quieter than the conversation names underneath it,
/// which left the list with nothing to scan by.
///
/// # The count, and when it is worth showing
///
/// Only while the section is collapsed. Open, the rows are right there and the number
/// beside the heading is a second, worse way to count them; collapsed, it is the only thing
/// that says how much is hidden. The accessibility label carries it either way, because a
/// screen reader has no rows in view to count.
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
            HStack(spacing: 8) {
                Image(systemName: section.symbol)
                    .font(.hiveSymbol(.headline, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: SidebarSection.symbolColumnWidth)
                    .accessibilityHidden(true)
                Text(section.title)
                    .font(.hive(.headline, weight: .bold))
                    .foregroundStyle(.primary)
                if !isExpanded {
                    Text("\(count)")
                        .font(.hive(.subheadline, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.hiveSymbol(.footnote, weight: .bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.22), value: isExpanded)
                    .frame(width: 14)
            }
            .padding(.top, Self.aboveTitle)
            // A section heading is a control, so it carries a full-height target.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // List section headers upper-case their text by default; the spec's headings are
        // title-case. Redundant now that this is an ordinary row, and kept so it stays
        // harmless if it is ever put back inside a `Section`.
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
    }

    /// Between the rule and the heading it introduces. The larger type needs the room:
    /// without it the title sits against the rule and the two read as one object.
    private static let aboveTitle: CGFloat = 6
}
