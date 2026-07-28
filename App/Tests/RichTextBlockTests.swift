import Foundation
@testable import Hive
import SwiftUI
import Testing

/// The constructs added for parity with upstream's renderer that are not tables:
/// thematic rules, task and radio items, `<u>` underlines, the emphasis that only
/// reaches the screen if it is stated as an attribute, and the inter-block spacing
/// rule.
@Suite("Rich text blocks")
struct RichTextBlockTests {
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

    @Test("a rule separates the paragraphs around it without swallowing either")
    func ruleBetweenParagraphs() {
        let blocks = RichTextParser.parse("above\n---\nbelow")
        #expect(blocks.count == 3)
        #expect(String(RichTextProbe.inline(of: blocks[0]).characters) == "above")
        #expect(blocks[1] == .rule)
        #expect(String(RichTextProbe.inline(of: blocks[2]).characters) == "below")
    }

    // MARK: - Task and radio items

    @Test("a GFM task list carries each item's tick")
    func taskList() {
        guard case let .bulletList(items) = RichTextParser.parse("- [ ] todo\n- [x] done").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map(\.marker) == [.checkbox(false), .checkbox(true)])
        #expect(items.map { String($0.content.characters) } == ["todo", "done"])
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
        #expect(String(items[0].content.characters) == "shipped")
    }

    @Test("a bare parenthesis line is a radio item")
    func bareRadio() {
        guard case let .bulletList(items) = RichTextParser.parse("( ) one\n(x) two").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map(\.marker) == [.radio(false), .radio(true)])
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
        guard case let .bulletList(children) = items[0].children.first else {
            Issue.record("expected a nested list")
            return
        }
        #expect(children.first?.marker == .checkbox(true))
    }

    // MARK: - `<u>` underline

    @Test("a u tag underlines its content and leaves no tag on screen")
    func underlineTag() {
        let attributed = InlineMarkdown.render("say <u>this</u> now")
        #expect(String(attributed.characters) == "say this now")
        let underlined = attributed.runs.filter { $0.underline == true }
        #expect(underlined.map { String(attributed[$0.range].characters) } == ["this"])
    }

    @Test("an unclosed u tag underlines to the end of the block")
    func unclosedUnderlineTag() {
        let attributed = InlineMarkdown.render("say <u>this")
        #expect(String(attributed.characters) == "say this")
        #expect(attributed.runs.contains { $0.underline == true })
    }

    @Test("a stray closing tag is left as the text it is")
    func strayClosingTag() {
        let attributed = InlineMarkdown.render("a </u> b")
        #expect(String(attributed.characters) == "a </u> b")
        #expect(!attributed.runs.contains { $0.underline == true })
    }

    @Test("a tag this renderer does not implement is left as written")
    func otherHTMLIsLiteral() {
        #expect(String(InlineMarkdown.render("x <b>y</b> z").characters) == "x <b>y</b> z")
    }

    // MARK: - Emphasis that has to be stated

    @Test("a struck run is given a strikethrough a Text will draw")
    func strikethroughIsStated() {
        let styled = RichTextStyle.styled(InlineMarkdown.render("a ~~gone~~ b"), base: .body)
        let struck = styled.runs.filter { $0.strikethroughStyle != nil }
        #expect(struck.map { String(styled[$0.range].characters) } == ["gone"])
    }

    @Test("a code span is given a monospaced face")
    func codeSpanIsMonospaced() {
        let styled = RichTextStyle.styled(InlineMarkdown.render("run `git log` first"), base: .body)
        let monospaced = styled.runs.filter { $0.font != nil }
        #expect(monospaced.map { String(styled[$0.range].characters) } == ["git log"])
    }

    @Test("bold and italic are left to the intent, so they keep scaling")
    func emphasisIsNotOverridden() {
        let styled = RichTextStyle.styled(InlineMarkdown.render("**b** and *i*"), base: .body)
        #expect(!styled.runs.contains { $0.font != nil })
    }

    @Test("an underlined run is given an underline a Text will draw")
    func underlineIsStated() {
        let styled = RichTextStyle.styled(InlineMarkdown.render("<u>x</u> y"), base: .body)
        let underlined = styled.runs.filter { $0.underlineStyle != nil }
        #expect(underlined.map { String(styled[$0.range].characters) } == ["x"])
    }

    // MARK: - Spacing

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
        let code = RichBlock.code("x", language: nil)
        let table = RichBlock.table(RichTable(alignments: [.leading], header: [], rows: []))
        #expect(RichTextSpacing.gap(after: paragraph, before: code) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.gap(after: table, before: paragraph) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.aroundBoxed > RichTextSpacing.regular)
    }

    @Test("a heading after a code block still opens a section")
    func headingBeatsBoxed() {
        let code = RichBlock.code("x", language: nil)
        let heading = RichBlock.heading(level: 1, AttributedString("H"))
        #expect(RichTextSpacing.gap(after: code, before: heading) == RichTextSpacing.beforeHeading)
    }

    @Test("two paragraphs of one thought stay close")
    func paragraphSpacing() {
        let paragraph = RichBlock.paragraph(AttributedString("p"))
        #expect(RichTextSpacing.gap(after: paragraph, before: paragraph) == RichTextSpacing.regular)
    }
}
