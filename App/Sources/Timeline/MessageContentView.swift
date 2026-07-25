import SwiftUI

/// Renders a message's rich content (kind-40002 markdown) as laid-out blocks —
/// paragraphs, headings, lists, block quotes, and fenced code — each with its own
/// treatment, falling back to a plain paragraph for anything the parser does not
/// recognise. Inline emphasis and safe links are carried in each block's
/// `AttributedString` (see ``MessageContent``).
///
/// The parse is memoised (``MessageContentCache``) so scrolling a long timeline never
/// re-parses the same content: a row that leaves and re-enters the viewport reuses the
/// blocks it produced before, keeping per-row work in the lazy stack minimal.
struct MessageContentView: View {
    let markdown: String

    private var blocks: [MessageBlock] {
        MessageContentCache.blocks(for: markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }
}

// MARK: - Block rendering

private extension MessageBlock {
    @ViewBuilder
    var view: some View {
        switch self {
        case let .paragraph(text):
            Text(text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .heading(level, text):
            Text(text)
                .font(Self.headingFont(level))
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity, alignment: .leading)

        case let .bulletList(items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    ListRow(marker: "•", content: item)
                }
            }

        case let .orderedList(items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    ListRow(marker: "\(index + 1).", content: item)
                }
            }

        case let .quote(text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                Text(text)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)

        case let .code(code, language):
            CodeBlock(code: code, language: language)
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

/// One list item: a marker column of fixed width so wrapped item text stays aligned
/// under the first line rather than under the marker.
private struct ListRow: View {
    let marker: String
    let content: AttributedString

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(marker)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(minWidth: 16, alignment: .trailing)
            Text(content)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// A fenced code block: monospaced, on a subtle fill, its raw text never inline-parsed.
/// Long lines wrap rather than scroll horizontally, so the block never fights the
/// timeline's vertical scroll.
private struct CodeBlock: View {
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

// MARK: - Parse memoisation

/// A small main-actor memo over ``MessageContent/parse(_:)``, so re-rendering the same
/// rich content during a scroll reuses its blocks instead of re-parsing markdown every
/// pass. Bounded so it never grows without limit on a long-lived session.
@MainActor
enum MessageContentCache {
    private final class Box {
        let blocks: [MessageBlock]
        init(_ blocks: [MessageBlock]) { self.blocks = blocks }
    }

    private static let cache: NSCache<NSString, Box> = {
        let cache = NSCache<NSString, Box>()
        cache.countLimit = 256
        return cache
    }()

    static func blocks(for markdown: String) -> [MessageBlock] {
        let key = markdown as NSString
        if let cached = cache.object(forKey: key) { return cached.blocks }
        let blocks = MessageContent.parse(markdown)
        cache.setObject(Box(blocks), forKey: key)
        return blocks
    }
}
