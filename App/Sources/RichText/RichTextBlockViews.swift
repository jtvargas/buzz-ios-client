import SwiftUI
import UIKit

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
            .foregroundStyle(isOn ? Color.hiveAccent : Color.secondary)
            .frame(minWidth: 16, alignment: .trailing)
            // The message around this is one combined VoiceOver element, so this label
            // is read inside the sentence — which is the only way the state reaches
            // somebody who cannot see the box.
            .accessibilityLabel(isOn ? "checked" : "unchecked")
    }
}

// MARK: - Headings

/// A markdown heading, and the rule a level-1 heading draws under itself.
///
/// Its own view rather than a case body in ``RichTextView`` because it is the one block
/// whose rendering branches on its own content, and that branch belongs with the thing
/// it is about.
struct RichHeadingView: View {
    let level: Int
    let text: AttributedString

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Semibold named while the font is built, not a `.fontWeight(.semibold)`
            // over it: the app's typeface drops a weight asked for by trait, so the
            // modifier this replaces drew every heading at body weight.
            RichTextInline.text(text, base: Self.style(level))
                .font(.hive(Self.style(level), weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
            // A rule under a level-1 heading and no other, matching upstream's
            // `autoAddDividerLineAfterH1`. It is what makes a `#` title read as the
            // top of a document rather than as a slightly larger sentence.
            if level == 1 {
                RichRuleView()
            }
        }
    }

    /// The system text style a markdown heading level is set at — a style rather than a
    /// built font, because the inline pass needs to name a weight against it.
    ///
    /// # Why the ladder starts where it does
    ///
    /// It used to be `title2 / title3 / headline / subheadline`, and the bottom half of
    /// that is not a ladder at all: `.headline` is **17pt, exactly `.body`**, so `###` —
    /// the level a written-up answer actually uses most — rendered as a bold sentence,
    /// and `####` and beyond rendered at `.subheadline`, *smaller than the text they
    /// introduce*. A heading that is not larger than its paragraph is not a heading.
    ///
    /// So every level now has its own size, and the three a message realistically reaches
    /// are all *above* body, with the fourth at body size on weight alone. The reference
    /// is the Flutter client, which takes gpt_markdown's Material defaults — h1–h4 at
    /// 32/28/24/22 against a 14pt body, or 2.3× down to 1.6×. Those ratios are for a
    /// document; in a conversation an `#` at 2.3× body is a shout, and this app's body is
    /// 17pt rather than 14pt, so the ladder is compressed to 1.6×–1.2× and keeps the last
    /// two levels at and below body on purpose — six hashes is a label, not a heading,
    /// which is what Material's own `titleSmall` says too.
    static func style(_ level: Int) -> Font.TextStyle {
        switch level {
        case 1: .title // 28pt, and the only level that also draws a rule
        case 2: .title2 // 22
        case 3: .title3 // 20
        case 4: .headline // 17, body size — the first level that leans on weight alone
        case 5: .subheadline // 15
        default: .footnote // 13
        }
    }
}

// MARK: - Code

/// A fenced code block: monospaced, on a subtle fill, its raw text never inline- or
/// entity-parsed.
///
/// Long lines scroll horizontally rather than wrap, which is what the mobile client
/// does and what this renderer used to differ from. Indentation is what a wrap costs:
/// a continued line restarts at the block's left edge, so the shape that carries the
/// structure is exactly the thing that goes, and the reader cannot tell a wrap from a
/// newline. A table scrolls for the neighbouring reason — a wrapped table is not a
/// table.
struct RichCodeBlock: View {
    @Environment(\.colorScheme) private var colorScheme

    let code: String
    let language: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let language, !language.isEmpty {
                HStack(spacing: 8) {
                    Text(language)
                        .font(.hive(.caption2))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Spacer(minLength: 0)
                    Button("Copy code", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = code
                    }
                    .labelStyle(.iconOnly)
                    .font(.hiveSymbol(.caption2))
                    .frame(width: 28, height: 28)
                    .accessibilityLabel("Copy code")
                }
            }
            ScrollView(.horizontal) {
                Text(RichCodeHighlighter.highlight(code, language: language, theme: theme))
                    .font(.hiveMono(fixedSize: RichCodeHighlighter.fontSize))
                    .foregroundStyle(.primary)
                    .lineSpacing(RichCodeHighlighter.fontSize * 0.5)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, language == nil || language?.isEmpty == true ? 6 : 2)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(uiColor: .secondarySystemBackground).opacity(0.60))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.70))
        )
    }

    private var theme: RichCodeTheme { colorScheme == .dark ? .dark : .light }
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
