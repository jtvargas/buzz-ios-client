import Foundation
@testable import Hive
import SwiftUI
import Testing

/// The constructs added for parity with upstream's renderer that are not tables:
/// thematic rules, task and radio items, `<u>` underlines, the emphasis that only
/// reaches the screen if it is stated as an attribute, and the inter-block spacing
/// rule.
@Suite("Rich text blocks")
// The suite keeps all non-table renderer constructs under one behavior boundary.
// swiftlint:disable:next type_body_length
struct RichTextBlockTests {
    private func inline(_ markdown: String) -> AttributedString {
        RichTextParser.parse(markdown).first.map(RichTextProbe.inline(of:)) ?? AttributedString()
    }

    // MARK: - Code highlighting

    @Test("the One Light scanner colours Swift tokens with the mobile map")
    func oneLightSwiftHighlighting() {
        let highlighted = RichCodeHighlighter.highlight(
            "let total: Int = 42 // count",
            language: "swift",
            theme: .light
        )
        let colors = highlighted.runs.compactMap(\.foregroundColor)
        #expect(colors.contains(RichCodeTheme.light.keyword))
        #expect(colors.contains(RichCodeTheme.light.type))
        #expect(colors.contains(RichCodeTheme.light.number))
        #expect(colors.contains(RichCodeTheme.light.comment))
    }

    @Test("the One Dark scanner colours JSON keys and values distinctly")
    func oneDarkJSONHighlighting() {
        let highlighted = RichCodeHighlighter.highlight(
            "{\"name\": \"Buzz\", \"enabled\": true}",
            language: "json",
            theme: .dark
        )
        let colors = highlighted.runs.compactMap(\.foregroundColor)
        #expect(colors.contains(RichCodeTheme.dark.name))
        #expect(colors.contains(RichCodeTheme.dark.string))
        #expect(colors.contains(RichCodeTheme.dark.type))
    }

    @Test("unknown and incomplete languages use unstyled base text")
    func codeHighlightFallback() {
        let unknown = RichCodeHighlighter.highlight("let x = 1", language: "haskell", theme: .light)
        let incomplete = RichCodeHighlighter.highlight("let title = \"Buzz", language: "swift", theme: .light)
        #expect(unknown.runs.allSatisfy { $0.foregroundColor == nil })
        #expect(incomplete.runs.allSatisfy { $0.foregroundColor == nil })
    }

    @Test(
        "a block comment opened near the end of the code does not take the app down",
        arguments: ["a/*b", "let a = 1 /*", "/*", "/*x", "x/*", "SELECT 1 /*"]
    )
    func unterminatedBlockCommentAtTheEnd(code: String) {
        // `starts("/*")` only needs two characters left, but the search for the closing
        // `*/` then walked `position + 2 ... characters.count - 2`. Once the opener is
        // inside the last four characters that range is inverted, which is a trap, not a
        // nil — "Range requires lowerBound <= upperBound", from a code block a reader
        // merely scrolled past. Every one of these is a snippet someone could paste.
        let highlighted = RichCodeHighlighter.highlight(code, language: "swift", theme: .light)
        #expect(highlighted.runs.allSatisfy { $0.foregroundColor == nil })
        // A colouring pass may never lose a character, whichever branch it takes.
        #expect(String(highlighted.characters) == code)
    }

    @Test("a scanned block is memoised, and the memo is keyed on all three inputs")
    func codeHighlightMemoises() {
        // `RichCodeBlock` is a plain value view, so its body re-runs whenever the row
        // holding it is re-evaluated — which this channel does on traffic that has
        // nothing to do with the message. Without the memo that is a fresh walk over
        // the whole block every time.
        //
        // Uniqued per run so an earlier test in this suite cannot have warmed the entry
        // and left this passing on someone else's work.
        let code = "let memoised = 42 // \(UUID().uuidString)"
        #expect(RichCodeHighlighter.memoisedText(code, language: "swift", theme: .light) == nil)

        let highlighted = RichCodeHighlighter.highlight(code, language: "swift", theme: .light)
        #expect(RichCodeHighlighter.memoisedText(code, language: "swift", theme: .light) == highlighted)

        // The other two inputs are not the same block. A key that dropped either would
        // serve One Light's palette to a reader in the dark, or one language's colours
        // to another's source — both of which look like a rendering bug, not a cache.
        #expect(RichCodeHighlighter.memoisedText(code, language: "swift", theme: .dark) == nil)
        #expect(RichCodeHighlighter.memoisedText(code, language: "json", theme: .light) == nil)
        #expect(RichCodeHighlighter.highlight(code, language: "swift", theme: .dark) != highlighted)
    }

    // MARK: - Thematic rules

    @Test(
        "a line of rule characters is a break",
        arguments: ["---", "***", "___", "- - -", "*****", "\u{2E3B}"]
    )
    func thematicBreaks(_ line: String) {
        #expect(RichTextParser.parse(line) == [.rule])
    }

    @Test(
        "a line that is not only rule characters is not a break",
        arguments: ["--", "**", "- item", "***bold***", "-- x"]
    )
    func notThematicBreaks(_ line: String) {
        #expect(!RichTextParser.parse(line).contains(.rule))
    }

    @Test("a blank-separated rule preserves the paragraphs around it")
    func blankSeparatedRule() {
        let blocks = RichTextParser.parse("above\n\n---\n\nbelow")
        #expect(blocks.count == 3)
        #expect(String(RichTextProbe.inline(of: blocks[0]).characters) == "above")
        #expect(blocks[1] == .rule)
        #expect(String(RichTextProbe.inline(of: blocks[2]).characters) == "below")
    }

    @Test("a consecutive dash underline is a setext heading, not a rule")
    func consecutiveDashUnderlineIsSetext() {
        let blocks = RichTextParser.parse("above\n---\nbelow")
        #expect(blocks.count == 2)
        guard case let .heading(level, heading) = blocks[0] else {
            Issue.record("expected a setext heading")
            return
        }
        #expect(level == 2)
        #expect(String(heading.characters) == "above")
        #expect(String(RichTextProbe.inline(of: blocks[1]).characters) == "below")
    }

    // MARK: - Task and radio items

    @Test("a GFM task list carries each item's tick")
    func taskList() {
        guard case let .bulletList(items) = RichTextParser.parse("- [ ] todo\n- [x] done").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map(\.marker) == [.checkbox(false), .checkbox(true)])
        #expect(items.map { String(RichTextProbe.inline(of: $0).characters) } == ["todo", "done"])
    }

    @Test("a task item and a plain item stay one list")
    func mixedTaskAndPlainList() {
        let blocks = RichTextParser.parse("- [ ] todo\n- plain")
        #expect(blocks.count == 1)
        guard case let .bulletList(items) = blocks[0] else {
            Issue.record("expected one bullet list")
            return
        }
        #expect(items.map(\.marker) == [.checkbox(false), nil])
    }

    @Test("a bare bracket line is a task item, as upstream draws it")
    func bareCheckbox() {
        guard case let .bulletList(items) = RichTextParser.parse("[x] shipped").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.first?.marker == .checkbox(true))
        #expect(String(RichTextProbe.inline(of: items[0]).characters) == "shipped")
    }

    @Test("a bare parenthesis line is a radio item")
    func bareRadio() {
        guard case let .bulletList(items) = RichTextParser.parse("( ) one\n(x) two").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map(\.marker) == [.radio(false), .radio(true)])
    }

    @Test("soft-broken bare markers become one multi-item list")
    func consecutiveBareMarkers() {
        guard case let .bulletList(items) = RichTextParser.parse("[ ] one\n[x] two\n( ) three").first else {
            Issue.record("expected one promoted list")
            return
        }
        #expect(items.count == 3)
        #expect(items.map(\.marker) == [.checkbox(false), .checkbox(true), .radio(false)])
        #expect(items.map { String(RichTextProbe.inline(of: $0).characters) } == ["one", "two", "three"])
    }

    @Test("an ordered item can carry a tick too")
    func orderedTaskItem() {
        guard case let .orderedList(_, items) = RichTextParser.parse("1. [x] shipped").first else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(items.first?.marker == .checkbox(true))
    }

    @Test(
        "a bracket that is not a tick stays in the text",
        arguments: ["[0] is the first element", "[y] maybe", "[]x nope", "[ ]no space"]
    )
    func notATaskItem(_ line: String) {
        let blocks = RichTextParser.parse(line)
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph for \(line)")
            return
        }
        #expect(String(text.characters) == line)
    }

    @Test("a nested task list still nests")
    func nestedTaskList() {
        guard case let .bulletList(items) = RichTextParser.parse("- top\n  - [x] inner").first else {
            Issue.record("expected a bullet list")
            return
        }
        guard case let .bulletList(children) = items[0].blocks.last else {
            Issue.record("expected a nested list")
            return
        }
        #expect(children.first?.marker == .checkbox(true))
    }

    // MARK: - `<u>` underline

    @Test("a u tag underlines its content and leaves no tag on screen")
    func underlineTag() {
        let attributed = inline("say <u>this</u> now")
        #expect(String(attributed.characters) == "say this now")
        let underlined = attributed.runs.filter { $0.underline == true }
        #expect(underlined.map { String(attributed[$0.range].characters) } == ["this"])
    }

    @Test("an unclosed u tag underlines to the end of the block")
    func unclosedUnderlineTag() {
        let attributed = inline("say <u>this")
        #expect(String(attributed.characters) == "say this")
        #expect(attributed.runs.contains { $0.underline == true })
    }

    @Test("a stray closing tag is left as the text it is")
    func strayClosingTag() {
        let attributed = inline("a </u> b")
        #expect(String(attributed.characters) == "a </u> b")
        #expect(!attributed.runs.contains { $0.underline == true })
    }

    @Test("a tag this renderer does not implement is left as written")
    func otherHTMLIsLiteral() {
        #expect(String(inline("x <b>y</b> z").characters) == "x <b>y</b> z")
    }

    // MARK: - Emphasis that has to be stated

    @Test("a struck run is given a strikethrough a Text will draw")
    func strikethroughIsStated() {
        let styled = RichTextStyle.styled(inline("a ~~gone~~ b"), base: .body)
        let struck = styled.runs.filter { $0.strikethroughStyle != nil }
        #expect(struck.map { String(styled[$0.range].characters) } == ["gone"])
    }

    @Test("a code span is given an explicit prose face")
    func codeSpanUsesExplicitProseFace() {
        let styled = RichTextStyle.styled(inline("run `git log` first"), base: .body)
        let monospaced = styled.runs.filter { $0.font != nil }
        #expect(monospaced.map { String(styled[$0.range].characters) } == ["git log"])
    }

    @Test("bold and italic are given named faces so Dynamic Type cannot drop their scale")
    func emphasisUsesExplicitFaces() {
        let styled = RichTextStyle.styled(inline("**b** and *i*"), base: .body)
        #expect(styled.runs.filter { $0.font != nil }.map { String(styled[$0.range].characters) } == ["b", "i"])
    }

    @Test("an underlined run is given an underline a Text will draw")
    func underlineIsStated() {
        let styled = RichTextStyle.styled(inline("<u>x</u> y"), base: .body)
        let underlined = styled.runs.filter { $0.underlineStyle != nil }
        #expect(underlined.map { String(styled[$0.range].characters) } == ["x"])
    }

    // MARK: - Spacing

    @Test("authored blank lines become bounded source spacers without leading or trailing air")
    func authoredBlankLines() {
        func spacerCount(_ markdown: String) -> Int {
            RichTextParser.parse(markdown).count { $0 == .sourceBlankLine }
        }

        #expect(spacerCount("above\n\nbelow") == 0)
        #expect(spacerCount("above\n\n\nbelow") == 1)
        #expect(spacerCount("above\n\n\n\nbelow") == 2)
        let sixBlankLines = (["above"] + Array(repeating: "", count: 6) + ["below"]).joined(separator: "\n")
        #expect(spacerCount(sixBlankLines) == 2)

        let blocks = RichTextParser.parse("\n\nabove\n\n\n\n\nbelow\n\n")
        #expect(blocks.first == .paragraph(AttributedString("above")))
        #expect(blocks.last == .paragraph(AttributedString("below")))
        #expect(blocks.filter { $0 == .sourceBlankLine }.count == RichTextParser.maxBlankLineRun - 1)
    }

    @Test("a source spacer owns its height instead of gaining semantic pair spacing")
    func sourceSpacerHasNoPairGap() {
        let paragraph = RichBlock.paragraph(AttributedString("p"))
        #expect(RichTextSpacing.gap(after: paragraph, before: .sourceBlankLine) == 0)
        #expect(RichTextSpacing.gap(after: .sourceBlankLine, before: paragraph) == 0)
    }

    @Test("source spacers never add whitespace to the one-line snippet")
    func sourceSpacerIsAbsentFromSnippet() {
        let message = RichMessage(blocks: [
            .sourceBlankLine,
            .paragraph(AttributedString("first")),
            .sourceBlankLine,
            .paragraph(AttributedString("second"))
        ])
        #expect(String(message.flattenedInline().characters) == "first second")
    }

    // MARK: - The heading ladder

    @Test("each heading level is set larger than the one below it")
    func headingLadderDescends() {
        let sizes = (1 ... 6).map { HiveTypography.size(of: RichHeadingView.style($0)) }
        #expect(sizes == sizes.sorted(by: >))
        // Strictly: two levels at one size are two levels a reader cannot tell apart,
        // which is what `###` and `####` both being 17pt used to be.
        #expect(Set(sizes).count == 6)
    }

    @Test("the levels a message actually uses are larger than the text they introduce")
    func headingsOutrankBody() {
        let body = HiveTypography.size(of: .body)
        // The regression this ladder exists for: `###` is the level a written-up answer
        // reaches for most, and it used to be `.headline` — 17pt, body size exactly — so
        // it read as a bold sentence rather than as a section.
        for level in 1 ... 3 {
            #expect(HiveTypography.size(of: RichHeadingView.style(level)) > body)
        }
        // Four leans on weight alone at body size, and the last two sit below it: six
        // hashes is a label, not a heading. What must never happen again is a level in
        // the first group being smaller than what it introduces.
        #expect(HiveTypography.size(of: RichHeadingView.style(4)) == body)
        #expect(HiveTypography.size(of: RichHeadingView.style(6)) < body)
    }

    @Test("a heading takes its space from above and hugs what follows")
    func headingSpacing() {
        let heading = RichBlock.heading(level: 2, AttributedString("H"))
        let paragraph = RichBlock.paragraph(AttributedString("p"))
        #expect(RichTextSpacing.gap(after: paragraph, before: heading) == RichTextSpacing.beforeHeading)
        #expect(RichTextSpacing.gap(after: heading, before: paragraph) == RichTextSpacing.afterHeading)
        #expect(RichTextSpacing.gap(after: heading, before: paragraph) < RichTextSpacing.regular)
    }

    @Test("a block that draws its own frame gets clear air on both sides")
    func boxedSpacing() {
        let paragraph = RichBlock.paragraph(AttributedString("p"))
        let code = RichBlock.code("x", info: nil)
        let table = RichBlock.table(RichTable(alignments: [.leading], header: [], rows: []))
        #expect(RichTextSpacing.gap(after: paragraph, before: code) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.gap(after: table, before: paragraph) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.aroundBoxed > RichTextSpacing.regular)
    }

    @Test("a heading after a code block still opens a section")
    func headingBeatsBoxed() {
        let code = RichBlock.code("x", info: nil)
        let heading = RichBlock.heading(level: 1, AttributedString("H"))
        #expect(RichTextSpacing.gap(after: code, before: heading) == RichTextSpacing.beforeHeading)
    }

    @Test("two paragraphs of one thought stay close")
    func paragraphSpacing() {
        let paragraph = RichBlock.paragraph(AttributedString("p"))
        #expect(RichTextSpacing.gap(after: paragraph, before: paragraph) == RichTextSpacing.regular)
    }

    @Test("the markdown spacing ladder keeps sections and boxed blocks ahead of paragraphs")
    func spacingHierarchyIsPreserved() {
        #expect(RichTextSpacing.beforeHeading >= RichTextSpacing.regular)
        #expect(RichTextSpacing.regular > RichTextSpacing.afterHeading)
        #expect(RichTextSpacing.aroundBoxed >= RichTextSpacing.regular)
    }
}
