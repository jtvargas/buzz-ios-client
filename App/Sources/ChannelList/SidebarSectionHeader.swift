import SwiftUI

/// One sidebar heading, Slack-style: a hairline rule, then a tappable expand/collapse
/// control with a rotating chevron, and — where the section can be added to — a `+`
/// before it.
///
/// The whole header is the hit target, not the chevron — a 12-pt glyph is not a control
/// anyone can hit, so the row is given a 44-pt minimum height and its own content shape.
/// The chevron rotates rather than swapping glyphs so the state change reads as one
/// continuous motion with the rows appearing beneath it.
///
/// # Which way the chevron points
///
/// Down when the section is closed, up when it is open — Slack's direction, and the one
/// that reads as "press this to pull the rows down" rather than as an arrow pointing at
/// the rows it already opened. It is still one glyph rotating: `chevron.down` turned a
/// half-turn *is* `chevron.up`, so the direction changes without the swap that would cost
/// the motion.
///
/// # Why the `+` is its own button
///
/// A control inside a control is a hit-testing coin flip in SwiftUI, so the header is not
/// one button with a `+` sitting on it: the title area and the chevron are each their own
/// expand/collapse target and the `+` is a third, between them. Three targets, one row,
/// no nesting.
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
    /// What the `+` does, or `nil` for a section nothing can be added to. Only Channels
    /// has one: a direct message is started from a person, an agent is not something this
    /// app makes, and Starred is a view of the other three.
    var create: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .accessibilityHidden(true)
            control
        }
    }

    private var control: some View {
        HStack(spacing: 8) {
            title
            if let create { createButton(create) }
            chevron
        }
        .padding(.top, Self.aboveTitle)
        // List section headers upper-case their text by default; the spec's headings are
        // title-case. Redundant now that this is an ordinary row, and kept so it stays
        // harmless if it is ever put back inside a `Section`.
        .textCase(nil)
    }

    /// The heading itself, and the larger of the two expand/collapse targets.
    private var title: some View {
        Button {
            toggle()
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
            }
            // A section heading is a control, so it carries a full-height target.
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        // The row emphasis, the same one the conversations underneath take: this target runs
        // the width of the list, and a heading that shrank under a finger would pull away
        // from both screen edges while the rows it introduces stayed where they were.
        .buttonStyle(.hivePress(.row))
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("\(section.title), \(count)")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")
    }

    private func createButton(_ create: @escaping () -> Void) -> some View {
        Button(action: create) {
            Image(systemName: "plus")
                .font(.hiveSymbol(.subheadline, weight: .semibold))
                .foregroundStyle(.secondary)
                // Square and full height so the glyph is not the target — the same
                // reason the heading carries a 44-pt minimum.
                .frame(width: 32, height: 44)
                .contentShape(.rect)
        }
        // A control and not the heading's row treatment, which is what keeps three targets on
        // one row legible under a finger: the `+` washes inside its own box, so a press here
        // says *this* was hit rather than lighting the whole heading it sits on.
        .buttonStyle(.hivePress)
        .accessibilityLabel(section.createLabel)
    }

    /// The second expand/collapse target. Hidden from assistive technology because the
    /// heading beside it already carries that action, its state, and its hint — two
    /// controls for one toggle is a list VoiceOver has to read twice.
    private var chevron: some View {
        Button {
            toggle()
        } label: {
            Image(systemName: Self.chevronSymbol)
                .font(.hiveSymbol(.footnote, weight: .bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .animation(.snappy(duration: 0.22), value: isExpanded)
                .frame(width: 14, height: 44)
                .contentShape(.rect)
        }
        // Named as a capsule rather than left on the shared corner radius: this target is
        // 14pt wide against 44 tall, and a 10pt radius on a sliver that narrow draws a wash
        // whose corners nearly meet in the middle — which reads as a shape that missed.
        .buttonStyle(.hivePress(.control, in: .capsule))
        .accessibilityHidden(true)
    }

    private func toggle() {
        withAnimation(.snappy(duration: 0.22)) { isExpanded.toggle() }
    }

    /// The glyph the chevron is drawn from, at rest — closed. Open, it is this turned a
    /// half-turn, which is `chevron.up`. Named so a test can hold the direction.
    static let chevronSymbol = "chevron.down"

    /// Between the rule and the heading it introduces. The larger type needs the room:
    /// without it the title sits against the rule and the two read as one object.
    private static let aboveTitle: CGFloat = 6
}
