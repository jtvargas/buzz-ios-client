import Foundation

/// One block of rendered message content. Kind-40002 rich content is CommonMark
/// markdown (the upstream editor serialises its document with `getMarkdown()`), so a
/// message can carry paragraphs, headings, lists, block quotes, and fenced code —
/// structure a single `Text` cannot lay out. Parsing it into typed blocks lets the
/// renderer give each its own treatment while keeping the parse pure and testable.
///
/// Inline emphasis inside a block (bold, italic, code spans, links) is carried in the
/// `AttributedString`, parsed inline-only and with unsafe link schemes stripped — see
/// ``MessageContent``.
enum MessageBlock: Equatable {
    /// A run of text. Soft line breaks inside it are preserved.
    case paragraph(AttributedString)
    /// A heading, level 1–6.
    case heading(level: Int, AttributedString)
    /// A bulleted list; each element is one item's inline content.
    case bulletList([AttributedString])
    /// A numbered list; each element is one item's inline content, rendered with a
    /// sequential marker.
    case orderedList([AttributedString])
    /// A block quote, its lines joined.
    case quote(AttributedString)
    /// A fenced code block: raw text (never inline-parsed) and an optional language
    /// hint from the opening fence.
    case code(String, language: String?)
}

/// Parses message markdown into renderable blocks, and renders inline markdown safely.
///
/// # Hardening
///
/// The content is untrusted — it is whatever a peer (or an agent) put on the wire — so
/// every parse is defensive:
///
/// - Inline markdown that fails to parse falls back to the raw text rather than
///   throwing (`AttributedString(markdown:)` is wrapped in `try?`).
/// - Links are sanitised: only `http`, `https`, and `mailto` survive as tappable
///   links. A `javascript:` or other-scheme link keeps its visible text but loses the
///   link attribute, so a tap can never hand an arbitrary URL to `openURL`.
/// - An unterminated code fence runs to the end of the message (CommonMark's rule),
///   so a stray ``` never swallows the parser or crashes it.
///
/// The parser is a pragmatic CommonMark *subset* — the constructs a chat/dev workspace
/// actually uses — not a conformant implementation. Anything it does not recognise
/// renders as a paragraph, which is always safe.
enum MessageContent {
    /// The link schemes a message may make tappable. Everything else is rendered as
    /// plain text, never as a link.
    static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

    // MARK: - Block parsing

    /// Splits `markdown` into typed blocks. Pure and deterministic.
    static func parse(_ markdown: String) -> [MessageBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [MessageBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                flushParagraph()
                blocks.append(codeBlock(lines, from: &index))
            } else if trimmed.isEmpty {
                flushParagraph()
                index += 1
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(quoteBlock(lines, from: &index))
            } else if isBullet(trimmed) {
                flushParagraph()
                blocks.append(bulletList(lines, from: &index))
            } else if isOrdered(trimmed) {
                flushParagraph()
                blocks.append(orderedList(lines, from: &index))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Block scanners

    /// Consumes a fenced code block from the opening fence at `index`. An unterminated
    /// fence runs to the end of the message.
    private static func codeBlock(_ lines: [String], from index: inout Int) -> MessageBlock {
        let fence = lines[index].trimmingCharacters(in: .whitespaces)
        let language = String(fence.dropFirst(3)).trimmingCharacters(in: .whitespaces)
        index += 1
        var code: [String] = []
        while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            code.append(lines[index])
            index += 1
        }
        if index < lines.count { index += 1 } // consume the closing fence
        return .code(code.joined(separator: "\n"), language: language.isEmpty ? nil : language)
    }

    /// Consumes consecutive `>`-prefixed lines into one quote block.
    private static func quoteBlock(_ lines: [String], from index: inout Int) -> MessageBlock {
        var quoted: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            quoted.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .quote(inline(quoted.joined(separator: "\n")))
    }

    /// Consumes consecutive bullet items (`-`, `*`, `+`).
    private static func bulletList(_ lines: [String], from index: inout Int) -> MessageBlock {
        var items: [AttributedString] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard isBullet(trimmed) else { break }
            items.append(inline(String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
            index += 1
        }
        return .bulletList(items)
    }

    /// Consumes consecutive ordered items (`1.`, `2)` …).
    private static func orderedList(_ lines: [String], from index: inout Int) -> MessageBlock {
        var items: [AttributedString] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard let content = orderedContent(trimmed) else { break }
            items.append(inline(content))
            index += 1
        }
        return .orderedList(items)
    }

    // MARK: - Line classifiers

    private static func heading(_ trimmed: String) -> MessageBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        guard rest.hasPrefix(" ") else { return nil } // CommonMark requires the space
        return .heading(level: level, inline(rest.trimmingCharacters(in: .whitespaces)))
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ")
    }

    private static func isOrdered(_ trimmed: String) -> Bool {
        orderedContent(trimmed) != nil
    }

    /// The content of an ordered-list line (`1. text` / `2) text`), or `nil` when the
    /// line is not an ordered item.
    private static func orderedContent(_ trimmed: String) -> String? {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let afterDigits = trimmed.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let afterDelimiter = afterDigits.dropFirst()
        guard afterDelimiter.hasPrefix(" ") else { return nil }
        return String(afterDelimiter).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Inline rendering

    /// Parses one block's inline markdown (bold, italic, code spans, links), preserving
    /// soft line breaks, with unsafe links stripped. Falls back to the raw text when the
    /// content is not valid markdown, so a malformed span never blanks a message.
    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        guard var attributed = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        sanitizeLinks(&attributed)
        return attributed
    }

    /// Strips the link attribute from any run whose URL is not an allowed scheme, so a
    /// tap can never open an arbitrary-scheme URL. The visible text is kept.
    private static func sanitizeLinks(_ attributed: inout AttributedString) {
        let disallowed = attributed.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            guard let scheme = url.scheme?.lowercased(), allowedLinkSchemes.contains(scheme) else {
                return run.range
            }
            return nil
        }
        for range in disallowed {
            attributed[range].link = nil
        }
    }
}
