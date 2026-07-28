import Foundation

/// Splits message markdown into typed ``RichBlock``s. Pure and deterministic — no
/// store, no view, no entity resolution (that is a separate pass over the result).
///
/// A pragmatic CommonMark *subset* — the constructs a chat/dev workspace actually
/// uses — not a conformant implementation. Anything it does not recognise renders as
/// a paragraph, which is always safe. Ported from the Phase-3 `MessageContent.parse`
/// block scanner, extended with indentation-based **nested lists**.
enum RichTextParser {
    /// The deepest list nesting the parser materialises. Untrusted input can carry
    /// arbitrarily increasing indentation; capping the level count bounds recursion
    /// so a pathological message can never blow the stack. Deeper items collapse
    /// into the deepest rendered level rather than being dropped.
    static let maxListDepth = 8

    // MARK: - Block parsing

    /// Splits `markdown` into typed blocks.
    static func parse(_ markdown: String) -> [RichBlock] {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [RichBlock] = []
        var paragraph: [String] = []
        var index = 0

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(InlineMarkdown.render(paragraph.joined(separator: "\n"))))
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
            } else if isThematicBreak(trimmed) {
                // Before the list scanner on purpose: `- - -` and `***` are both a rule
                // and (by the first character alone) a bullet, and CommonMark resolves
                // the ambiguity in the rule's favour.
                flushParagraph()
                blocks.append(.rule)
                index += 1
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
            } else if trimmed.hasPrefix(">") {
                flushParagraph()
                blocks.append(quoteBlock(lines, from: &index))
            } else if isTableStart(lines, at: index) {
                flushParagraph()
                blocks.append(tableBlock(lines, from: &index))
            } else if listLine(line) != nil {
                flushParagraph()
                blocks.append(contentsOf: listBlocks(lines, from: &index))
            } else {
                paragraph.append(line)
                index += 1
            }
        }
        flushParagraph()
        return blocks
    }

    // MARK: - Block scanners

    /// Consumes a fenced code block from the opening fence at `index`. An
    /// unterminated fence runs to the end of the message.
    private static func codeBlock(_ lines: [String], from index: inout Int) -> RichBlock {
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
    private static func quoteBlock(_ lines: [String], from index: inout Int) -> RichBlock {
        var quoted: [String] = []
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(">") else { break }
            quoted.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
            index += 1
        }
        return .quote(InlineMarkdown.render(quoted.joined(separator: "\n")))
    }

    // MARK: - Line classifiers

    private static func heading(_ trimmed: String) -> RichBlock? {
        guard trimmed.hasPrefix("#") else { return nil }
        let level = trimmed.prefix { $0 == "#" }.count
        guard level <= 6 else { return nil }
        let rest = trimmed.dropFirst(level)
        // CommonMark requires the space — and this is exactly what keeps a
        // line-starting `#channel` (no space) out of the heading branch and in a
        // paragraph, where the entity pass can resolve it. The ZWSP guard other
        // renderers need is unnecessary here because block classification is
        // separate from inline parsing.
        guard rest.hasPrefix(" ") else { return nil }
        return .heading(level: level, InlineMarkdown.render(rest.trimmingCharacters(in: .whitespaces)))
    }

    /// Whether `trimmed` is a thematic break: CommonMark's three-or-more `-`, `*`, or
    /// `_` (spaces between them allowed, nothing else on the line), or the reference
    /// renderer's own `⸻`.
    ///
    /// The `_` and `*` forms are a superset of what upstream draws — its `HrLine`
    /// matches dashes and `⸻` only. Accepting all three costs nothing and cannot
    /// swallow text: a line of nothing but rule characters has no content to lose, and
    /// `***bold***` is disqualified by the letters in it.
    static func isThematicBreak(_ trimmed: String) -> Bool {
        let stripped = trimmed.filter { !$0.isWhitespace }
        guard let first = stripped.first, stripped.allSatisfy({ $0 == first }) else { return false }
        if first == "\u{2E3B}" { return true } // ⸻, upstream's own rule character
        guard first == "-" || first == "*" || first == "_" else { return false }
        return stripped.count >= 3
    }
}
