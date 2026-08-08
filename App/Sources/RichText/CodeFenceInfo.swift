import Foundation

/// The display language and syntax-highlighter language parsed from a CommonMark
/// fenced-code info string.
struct CodeFenceInfo: Equatable, Sendable {
    private static let highlightAliases = [
        "sh": "bash",
        "shell": "bash",
        "zsh": "bash"
    ]

    /// The first whitespace-separated token, shown above the code block.
    let language: String
    /// The grammar name handed to ``RichCodeHighlighter``.
    let highlightLanguage: String

    init?(rawInfoString: String?) {
        guard let language = rawInfoString?
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased(),
            !language.isEmpty
        else { return nil }
        self.language = language
        self.highlightLanguage = Self.highlightAliases[language] ?? language
    }
}
