import SwiftUI

/// A deliberately short-lived probe for iOS 26's attributed `TextEditor` selection.
struct MarkdownTextEditorProbe: View {
    @State private var text: AttributedString
    @State private var selection = AttributedTextSelection()

    init(blocks: [RichBlock]) {
        _text = State(initialValue: Self.attributedText(blocks))
    }

    var body: some View {
        TextEditor(text: $text, selection: $selection)
            .font(.hive(.body))
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private extension MarkdownTextEditorProbe {
    static func attributedText(_ blocks: [RichBlock]) -> AttributedString {
        AttributedString(blocks.map(plainText).joined(separator: "\n\n"))
    }

    static func plainText(_ block: RichBlock) -> String {
        switch block {
        case let .paragraph(text), let .quote(text):
            String(text.characters)
        case let .heading(_, text):
            String(text.characters)
        case let .bulletList(items):
            listText(items, ordered: false, start: 1)
        case let .orderedList(start, items):
            listText(items, ordered: true, start: start)
        case .code, .table, .rule, .media, .linkPreview:
            ""
        }
    }

    static func listText(_ items: [RichListItem], ordered: Bool, start: Int) -> String {
        items.enumerated().map { index, item in
            let marker = ordered ? "\(start + index)." : "•"
            return "\(marker) \(String(item.content.characters))"
        }.joined(separator: "\n")
    }
}
