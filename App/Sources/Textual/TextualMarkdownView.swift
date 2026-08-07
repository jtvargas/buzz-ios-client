import SwiftUI
import Textual

/// The shared Textual surface used by messages and markdown documents in this POC.
struct TextualMarkdownView: View {
    let markdown: String
    var baseURL: URL?
    let style: TextualRenderingStyle

    @ViewBuilder
    var body: some View {
        switch style {
        case .gitHub:
            content
                .textual.structuredTextStyle(.gitHub)
        case .default:
            content
                .textual.structuredTextStyle(.default)
        }
    }

    private var content: some View {
        StructuredText(markdown: markdown, baseURL: baseURL)
            .textual.textSelection(.enabled)
    }
}
