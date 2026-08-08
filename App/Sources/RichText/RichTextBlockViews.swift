import SwiftUI
import UIKit

// The leaf block views a message is drawn from — lists, code, and the thematic rule.
// Split out of `RichTextView.swift` so that file is about the message's own layout.

// MARK: - Recursive blocks

/// One block at any level of the rich-content tree. Only recursive branches are type
/// erased, breaking their result-type cycle without erasing ordinary message blocks.
struct RichBlockView: View {
    @Environment(\.claimRowTap) private var claimRowTap
    @Environment(\.openURL) private var openURL

    let block: RichBlock
    var attribution: MessageMediaAttribution?
    var listDepth = 0

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        switch block {
        case let .paragraph(text):
            RichTextInline.text(text, base: .body)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .heading(level, text):
            RichHeadingView(level: level, text: text)
        case let .quote(blocks):
            AnyView(RichQuoteView(blocks: blocks, attribution: attribution, listDepth: listDepth))
        case let .code(code, info):
            RichCodeBlock(code: code, info: info)
        case let .bulletList(items):
            AnyView(RichListView(
                items: items,
                ordered: false,
                start: 1,
                depth: listDepth,
                attribution: attribution
            ))
        case let .orderedList(start, items):
            AnyView(RichListView(
                items: items,
                ordered: true,
                start: start,
                depth: listDepth,
                attribution: attribution
            ))
        case let .table(table):
            RichTableView(table: table)
        case .rule:
            RichRuleView()
        case .sourceBlankLine:
            Text(verbatim: " ")
                .font(.hive(.body))
                .hidden()
                .accessibilityHidden(true)
        case let .media(media):
            MessageMediaGroupView(media: media, onTap: { claimRowTap?() }, attribution: attribution)
        case let .linkPreview(preview):
            LinkPreviewCardView(preview: preview) { openURL(preview.url) }
        }
    }
}

private struct RichBlockStack: View {
    @ScaledMetric(relativeTo: .body) private var blockSpacingScale: CGFloat = 1

    let blocks: [RichBlock]
    let attribution: MessageMediaAttribution?
    let listDepth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                RichBlockView(block: block, attribution: attribution, listDepth: listDepth)
                    .padding(.top, gapAbove(index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func gapAbove(_ index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return RichTextSpacing.gap(after: blocks[index - 1], before: blocks[index]) * blockSpacingScale
    }
}

private struct RichQuoteView: View {
    let blocks: [RichBlock]
    let attribution: MessageMediaAttribution?
    let listDepth: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color.secondary.opacity(0.5))
                .frame(width: 3)
            if case let .paragraph(text)? = blocks.count == 1 ? blocks.first : nil {
                // Preserve the exact pre-AST leaf path; no extra stack changes its
                // baseline, wrapping, or ideal-height behavior.
                RichTextInline.text(text, base: .body)
                    .font(.hive(.body))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                RichBlockStack(blocks: blocks, attribution: attribution, listDepth: listDepth)
                    .foregroundStyle(.secondary)
            }
        }
        .richTextIdealHeight()
    }
}

// MARK: - Lists

/// A (possibly nested) list. Renders each item's marker + content, then recurses into
/// that item's child lists indented one level deeper.
struct RichListView: View {
    let items: [RichListItem]
    let ordered: Bool
    let start: Int
    var depth: Int = 0
    var attribution: MessageMediaAttribution?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                RichListItemView(
                    ordinal: ordinal(index),
                    item: item,
                    depth: depth,
                    attribution: attribution
                )
            }
        }
        .padding(.leading, depth == 0 ? 0 : RichTextStyle.nestedIndent)
    }

    private func ordinal(_ index: Int) -> String {
        ordered ? "\(start + index)." : "•"
    }

}

private struct RichListItemView: View {
    let ordinal: String
    let item: RichListItem
    let depth: Int
    let attribution: MessageMediaAttribution?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if case let .paragraph(text)? = item.blocks.first {
                RichListRow(ordinal: ordinal, text: text, marker: item.marker)
                ForEach(Array(item.blocks.dropFirst().enumerated()), id: \.offset) { _, block in
                    RichBlockView(block: block, attribution: attribution, listDepth: depth + 1)
                        .padding(.leading, block.isList ? 0 : 22)
                }
            } else {
                HStack(alignment: .top, spacing: 6) {
                    RichListMarkerView(ordinal: ordinal, marker: item.marker)
                    RichBlockStack(blocks: item.blocks, attribution: attribution, listDepth: depth + 1)
                }
            }
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
    let text: AttributedString
    let marker: RichListMarker?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            RichListMarkerView(ordinal: ordinal, marker: marker)
            RichTextInline.text(text, base: .body)
                .font(.hive(.body))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // The row is as tall as the item's own text. An `HStack` sizes its children
        // against the height it was offered, and an item offered one line's worth
        // truncates the rest of the sentence with an ellipsis instead of wrapping —
        // which is what a numbered list of long items showed on device. The quote block
        // below has carried the same modifier since it was written.
        .richTextIdealHeight()
    }

}

private struct RichListMarkerView: View {
    let ordinal: String
    let marker: RichListMarker?

    @ViewBuilder var body: some View {
        switch marker {
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

private extension RichBlock {
    var isList: Bool {
        switch self {
        case .bulletList, .orderedList: true
        default: false
        }
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
    let info: CodeFenceInfo?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let info {
                HStack(spacing: 8) {
                    Text(info.language)
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
                Text(RichCodeHighlighter.highlight(code, language: info?.highlightLanguage, theme: theme))
                    .font(.hiveMono(fixedSize: RichCodeHighlighter.fontSize))
                    .foregroundStyle(.primary)
                    .lineSpacing(RichCodeHighlighter.fontSize * 0.5)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, info == nil ? 6 : 2)
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
