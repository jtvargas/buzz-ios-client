import SwiftUI

// The leaf block views a message is drawn from — lists, code, and the thematic rule.
// Split out of `RichTextView.swift` so that file is about the message's own layout.

// MARK: - Lists

/// A (possibly nested) list. Renders each item's marker + content, then recurses into
/// that item's child lists indented one level deeper.
struct RichListView: View {
    let items: [RichListItem]
    let ordered: Bool
    let start: Int
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    RichListRow(ordinal: ordinal(index), item: item)
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        childList(child)
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : RichTextStyle.nestedIndent)
    }

    private func ordinal(_ index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }

    @ViewBuilder
    private func childList(_ block: RichBlock) -> some View {
        switch block {
        case let .bulletList(items):
            RichListView(items: items, ordered: false, start: 1, depth: depth + 1)
        case let .orderedList(start, items):
            RichListView(items: items, ordered: true, start: start, depth: depth + 1)
        default:
            EmptyView() // children are only ever nested lists
        }
    }
}

/// One list item's row: a fixed-width marker column so wrapped item text stays aligned
/// under the first line rather than under the marker.
///
/// A task item draws its box or dial *instead of* the list's bullet, not beside it.
/// Upstream draws both — a bullet and then a checkbox — because its list component
/// re-parses the item's text and finds a checkbox in it. Two markers for one item is
/// noise at phone width, and every renderer an author is likely to have written the
/// list against (GitHub included) shows the box alone.
///
/// The box is deliberately inert. There is no wire format for ticking someone else's
/// checkbox — an edit would have to republish the whole message — so it states the
/// author's state and nothing more, which is also what upstream's does.
private struct RichListRow: View {
    /// The bullet or number this item would draw without a marker of its own.
    let ordinal: String
    let item: RichListItem

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            RichTextInline.text(item.content, base: .body)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var marker: some View {
        switch item.marker {
        case .none:
            Text(ordinal)
                .font(.hive(.body))
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
        case let .checkbox(isOn):
            symbol(isOn ? "checkmark.square.fill" : "square", isOn: isOn)
        case let .radio(isOn):
            symbol(isOn ? "largecircle.fill.circle" : "circle", isOn: isOn)
        }
    }

    private func symbol(_ name: String, isOn: Bool) -> some View {
        Image(systemName: name)
            .font(.hiveSymbol(.body))
            .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            .frame(minWidth: 16, alignment: .trailing)
            // The message around this is one combined VoiceOver element, so this label
            // is read inside the sentence — which is the only way the state reaches
            // somebody who cannot see the box.
            .accessibilityLabel(isOn ? "checked" : "unchecked")
    }
}

// MARK: - Code

/// A fenced code block: monospaced, on a subtle fill, its raw text never inline- or
/// entity-parsed.
///
/// Long lines wrap rather than scroll, which is the one place this renderer knowingly
/// differs from upstream — upstream scrolls the code horizontally. Wrapping loses no
/// character either way, and it is the reading that needs no gesture. A table gets the
/// scroll instead because a wrapped table is not a table; wrapped code is still code.
struct RichCodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                // Above the code, not floating over its top-right corner. As an overlay
                // it sat on top of the first line, so any block whose opening line ran
                // the full width had the label printed through it.
                Text(language)
                    .font(.hive(.caption2))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(code)
                // Named, not `.monospaced()`: the app's family is Lato and has no
                // fixed-width member for that modifier to find.
                .font(.hiveMono(.callout))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.secondary.opacity(0.12))
        )
    }
}

// MARK: - Rule

/// A thematic break, and the divider a level-1 heading draws under itself.
///
/// Its own view rather than a bare `Divider()` so the padding that keeps blocks off it
/// lives with it — and so ``RichTextSpacing`` reasons about one rule shape, whether the
/// author wrote `---` or the renderer put one under a title.
struct RichRuleView: View {
    var body: some View {
        Divider()
            .padding(.vertical, RichTextStyle.ruleSpacing)
            .accessibilityHidden(true)
    }
}
