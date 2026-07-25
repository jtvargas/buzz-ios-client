import SwiftUI

/// How ``RichTextView`` lays a message out.
enum RichTextRenderMode {
    /// Full block layout — paragraphs, headings, quotes, code, and (nested) lists.
    case full
    /// A single truncated line — the whole message flattened, for previews and the
    /// channel-list snippet.
    case snippet
}

/// The one app-wide message renderer. Consumes a parsed, entity-resolved
/// ``RichMessage`` and lays out each block, mapping ``MentionAttribute`` /
/// ``ChannelAttribute`` runs to accent + weight (see ``RichTextStyle``) so mentions
/// and channels look and behave identically on every surface. Replaces the Phase-3
/// `MessageContentView`.
///
/// Each inline is one `Text(attributedString)` — free Dynamic Type, wrapping, and
/// VoiceOver, and unit-testable as data. Text selection is deliberately not enabled
/// here: the message body's tap opens the thread (a later workstream), and Copy
/// lives in the long-press menu.
struct RichTextView: View {
    let message: RichMessage
    var mode: RichTextRenderMode = .full

    /// Renders an already-parsed, already-resolved message.
    init(_ message: RichMessage, mode: RichTextRenderMode = .full) {
        self.message = message
        self.mode = mode
    }

    /// Parses and resolves `text` through the memo, then renders it. The convenience
    /// the timeline uses — a cache hit on a re-render is cheap.
    init(text: String, resolver: MentionResolver, mode: RichTextRenderMode = .full) {
        self.init(RichMessageCache.message(for: text, resolver: resolver), mode: mode)
    }

    var body: some View {
        switch mode {
        case .full: full
        case .snippet: snippet
        }
    }
}

// MARK: - Layout

private extension RichTextView {
    var full: some View {
        VStack(alignment: .leading, spacing: RichTextStyle.blockSpacing) {
            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var snippet: some View {
        Text(RichTextStyle.styled(message.flattenedInline(), base: .body))
            .font(.body)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    @ViewBuilder
    func blockView(_ block: RichBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(RichTextStyle.styled(text, base: .body))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            let font = Self.headingFont(level)
            Text(RichTextStyle.styled(text, base: font))
                .font(font)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(RichTextStyle.styled(text, base: .body))
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(code, language):
            RichCodeBlock(code: code, language: language)

        case let .bulletList(items):
            RichListView(items: items, ordered: false, start: 1)

        case let .orderedList(start, items):
            RichListView(items: items, ordered: true, start: start)
        }
    }

    /// A Dynamic-Type-scaling heading font per markdown level.
    static func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }
}

// MARK: - Lists

/// A (possibly nested) list. Renders each item's marker + content, then recurses
/// into that item's child lists indented one level deeper.
private struct RichListView: View {
    let items: [RichListItem]
    let ordered: Bool
    let start: Int
    var depth: Int = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 2) {
                    RichListRow(marker: marker(index), content: item.content)
                    ForEach(Array(item.children.enumerated()), id: \.offset) { _, child in
                        childList(child)
                    }
                }
            }
        }
        .padding(.leading, depth == 0 ? 0 : RichTextStyle.nestedIndent)
    }

    private func marker(_ index: Int) -> String {
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

/// One list item's row: a fixed-width marker column so wrapped item text stays
/// aligned under the first line rather than under the marker.
private struct RichListRow: View {
    let marker: String
    let content: AttributedString

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(RichTextStyle.styled(content, base: .body))
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Code

/// A fenced code block: monospaced, on a subtle fill, its raw text never inline- or
/// entity-parsed. Long lines wrap rather than scroll, so the block never fights the
/// timeline's vertical scroll.
private struct RichCodeBlock: View {
    let code: String
    let language: String?

    var body: some View {
        Text(code)
            .font(.system(.callout, design: .monospaced))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(alignment: .topTrailing) {
                if let language, !language.isEmpty {
                    Text(language)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(6)
                        .accessibilityHidden(true)
                }
            }
    }
}
