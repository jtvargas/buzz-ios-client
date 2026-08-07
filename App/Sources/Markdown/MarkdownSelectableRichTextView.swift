import SwiftUI

/// A document renderer that joins adjacent prose blocks into one selectable `Text`.
///
/// Tables, fenced code, media and rules stay in ``RichTextView`` because each owns layout
/// a `Text` cannot express. The prose between those boundaries is one `Text`, so the system
/// can drag a selection from a heading into the paragraphs and lists that follow it.
struct MarkdownSelectableRichTextView: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @ScaledMetric(relativeTo: .body) private var blockSpacingScale: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 20

    @State private var flashing: String?
    @State private var flashToken = 0

    let message: RichMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.units(for: message.blocks)) { unit in
                unitView(unit)
                    .padding(.top, gapAbove(unit))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textRenderer(
            RichTextEntityRenderer(flashing: flashing, dark: colorScheme == .dark)
        )
        .environment(\.openURL, OpenURLAction { url in
            flash(url)
            return .handled
        })
    }

    @ViewBuilder
    private func unitView(_ unit: Unit) -> some View {
        switch unit.content {
        case let .prose(blocks):
            MarkdownTextEditorProbe(blocks: blocks)
        case let .isolated(block):
            RichTextView(RichMessage(blocks: [block]))
        }
    }

    /// The exact cost of making prose one selection range: layout between blocks becomes
    /// authored newline glyphs. That preserves the words and inline styles, but not a quote's
    /// drawn bar, a level-one heading's rule, or a list's hanging indent.
    private func proseText(_ blocks: [RichBlock]) -> Text {
        blocks.enumerated().reduce(Text("")) { result, pair in
            let (index, block) = pair
            guard index > 0 else { return Self.text(for: block) }
            let gap = RichTextSpacing.gap(after: blocks[index - 1], before: block)
                * blockSpacingScale
            return Text(
                "\(result)\(Self.separator(height: bodyLineHeight + gap))\(Self.text(for: block))"
            )
        }
    }

    private func gapAbove(_ unit: Unit) -> CGFloat {
        guard unit.startIndex > 0 else { return 0 }
        return RichTextSpacing.gap(
            after: message.blocks[unit.startIndex - 1],
            before: message.blocks[unit.startIndex]
        ) * blockSpacingScale
    }

    private func flash(_ url: URL) {
        flashToken += 1
        let token = flashToken
        withAnimation(.easeOut(duration: 0.08)) { flashing = url.absoluteString }
        Task { @MainActor in
            try? await Task.sleep(for: RichTextView.flashDuration)
            guard flashToken == token else { return }
            withAnimation(.easeOut(duration: 0.18)) { flashing = nil }
        }
        openURL(url)
    }
}

private extension MarkdownSelectableRichTextView {
    enum UnitContent {
        case prose([RichBlock])
        case isolated(RichBlock)
    }

    struct Unit: Identifiable {
        let startIndex: Int
        let content: UnitContent

        var id: Int { startIndex }
    }

    static func units(for blocks: [RichBlock]) -> [Unit] {
        var units: [Unit] = []
        var prose: [RichBlock] = []
        var proseStart = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            units.append(Unit(startIndex: proseStart, content: .prose(prose)))
            prose.removeAll(keepingCapacity: true)
        }

        for (index, block) in blocks.enumerated() {
            if isProse(block) {
                if prose.isEmpty { proseStart = index }
                prose.append(block)
            } else {
                flushProse()
                units.append(Unit(startIndex: index, content: .isolated(block)))
            }
        }
        flushProse()
        return units
    }

    static func isProse(_ block: RichBlock) -> Bool {
        switch block {
        case .paragraph, .heading, .quote, .bulletList, .orderedList:
            true
        case .code, .table, .rule, .media, .linkPreview:
            false
        }
    }

    static func separator(height: CGFloat) -> Text {
        var separator = AttributedString("\n")
        separator.lineHeight = .exact(points: height)
        return Text(separator)
    }

    static func text(for block: RichBlock) -> Text {
        switch block {
        case let .paragraph(text):
            RichTextInline.text(text, base: .body)
        case let .heading(level, text):
            RichTextInline.text(text, base: RichHeadingView.style(level))
                .font(.hive(RichHeadingView.style(level), weight: .semibold))
        case let .quote(text):
            Text("› \(RichTextInline.text(text, base: .body))")
        case let .bulletList(items):
            listText(items, ordered: false, start: 1)
        case let .orderedList(start, items):
            listText(items, ordered: true, start: start)
        case .code, .table, .rule, .media, .linkPreview:
            Text("")
        }
    }

    static func listText(
        _ items: [RichListItem],
        ordered: Bool,
        start: Int,
        depth: Int = 0
    ) -> Text {
        items.enumerated().reduce(Text("")) { result, pair in
            let (index, item) = pair
            let lineBreak = index == 0 ? Text("") : Text("\n")
            let indent = String(repeating: "    ", count: depth)
            let marker = marker(for: item, ordinal: ordered ? "\(start + index)." : "•")
            var row = Text("\(indent)\(marker) \(RichTextInline.text(item.content, base: .body))")
            for child in item.children {
                row = Text("\(row)\n\(childListText(child, depth: depth + 1))")
            }
            return Text("\(result)\(lineBreak)\(row)")
        }
    }

    static func childListText(_ block: RichBlock, depth: Int) -> Text {
        switch block {
        case let .bulletList(items):
            listText(items, ordered: false, start: 1, depth: depth)
        case let .orderedList(start, items):
            listText(items, ordered: true, start: start, depth: depth)
        default:
            Text("")
        }
    }

    static func marker(for item: RichListItem, ordinal: String) -> String {
        switch item.marker {
        case .none: ordinal
        case let .checkbox(isOn): isOn ? "☑" : "☐"
        case let .radio(isOn): isOn ? "◉" : "○"
        }
    }
}
