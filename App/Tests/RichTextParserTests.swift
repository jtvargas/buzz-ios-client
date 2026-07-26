import Foundation
@testable import Hive
import Testing

/// The block parser and its inline hardening: block classification, the CommonMark
/// subset the workspace uses, nested lists, and unsafe-link stripping. Pure and
/// deterministic — no store, no view, no resolver.
@Suite("Rich text parsing")
struct RichTextParserTests {
    // MARK: - Blocks

    @Test("plain text is one paragraph")
    func plainParagraph() {
        let blocks = RichTextParser.parse("just a line of text")
        #expect(blocks == [.paragraph(AttributedString("just a line of text"))])
    }

    @Test("empty content yields no blocks")
    func emptyContent() {
        #expect(RichTextParser.parse("").isEmpty)
    }

    @Test("a hash-prefixed line is a heading at its level")
    func heading() {
        guard case let .heading(level, text) = RichTextParser.parse("## Section").first else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(String(text.characters) == "Section")
    }

    @Test("more than six hashes is not a heading")
    func tooManyHashes() {
        let blocks = RichTextParser.parse("####### not a heading")
        #expect(blocks.count == 1)
        if case .heading = blocks[0] { Issue.record("should not be a heading") }
    }

    @Test("a hash with no space is a paragraph, not a heading — the #channel guard")
    func hashWithoutSpace() {
        let blocks = RichTextParser.parse("#general channel")
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters) == "#general channel")
    }

    @Test("dash, star, and plus all start bullet items")
    func bulletMarkers() {
        guard case let .bulletList(items) = RichTextParser.parse("- one\n* two\n+ three").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map { String($0.content.characters) } == ["one", "two", "three"])
    }

    @Test("numbered lines form an ordered list carrying its start")
    func orderedList() {
        guard case let .orderedList(start, items) = RichTextParser.parse("3. first\n4) second").first else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(start == 3)
        #expect(items.map { String($0.content.characters) } == ["first", "second"])
    }

    @Test("a marker-kind change at the same indentation starts a sibling list")
    func adjacentMixedLists() {
        let blocks = RichTextParser.parse("- bullet\n1. numbered\n2. second")
        #expect(blocks.count == 2)
        guard case let .bulletList(bullets) = blocks[0],
              case let .orderedList(start, numbered) = blocks[1]
        else {
            Issue.record("expected adjacent bullet and ordered lists")
            return
        }
        #expect(bullets.map { String($0.content.characters) } == ["bullet"])
        #expect(start == 1)
        #expect(numbered.map { String($0.content.characters) } == ["numbered", "second"])
    }

    @Test("a fenced code block keeps its raw text and language, unparsed")
    func fencedCode() {
        let blocks = RichTextParser.parse("```swift\nlet x = *notBold*\n```")
        #expect(blocks == [.code("let x = *notBold*", language: "swift")])
    }

    @Test("an unterminated fence runs to the end of the message")
    func unterminatedFence() {
        let blocks = RichTextParser.parse("```\ncode line 1\ncode line 2")
        #expect(blocks == [.code("code line 1\ncode line 2", language: nil)])
    }

    @Test("a > line is a block quote")
    func blockQuote() {
        guard case let .quote(text) = RichTextParser.parse("> quoted words").first else {
            Issue.record("expected a quote")
            return
        }
        #expect(String(text.characters) == "quoted words")
    }

    @Test("a mixed document parses into the expected block sequence")
    func mixedDocument() {
        let blocks = RichTextParser.parse("# Title\n\npara text\n\n- a\n- b\n\n```\ncode\n```")
        #expect(blocks.count == 4)
        if case .heading(1, _) = blocks[0] {} else { Issue.record("block 0 heading") }
        if case .paragraph = blocks[1] {} else { Issue.record("block 1 paragraph") }
        if case .bulletList = blocks[2] {} else { Issue.record("block 2 bullets") }
        if case .code = blocks[3] {} else { Issue.record("block 3 code") }
    }

    // MARK: - Nested lists

    @Test("an indented bullet nests under the item above it")
    func nestedBulletList() {
        guard case let .bulletList(items) = RichTextParser.parse("- a\n  - b\n  - c\n- d").first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.count == 2)
        #expect(String(items[0].content.characters) == "a")
        guard case let .bulletList(children) = items[0].children.first else {
            Issue.record("expected a nested bullet list under item a")
            return
        }
        #expect(children.map { String($0.content.characters) } == ["b", "c"])
        #expect(items[1].children.isEmpty)
    }

    @Test("an ordered sub-list nests under a bullet item, keeping its start")
    func nestedOrderedUnderBullet() {
        guard case let .bulletList(items) = RichTextParser.parse("- a\n  1. x\n  2. y").first else {
            Issue.record("expected a bullet list")
            return
        }
        guard case let .orderedList(start, children) = items[0].children.first else {
            Issue.record("expected a nested ordered list")
            return
        }
        #expect(start == 1)
        #expect(children.map { String($0.content.characters) } == ["x", "y"])
    }

    @Test("runaway indentation is depth-clamped, never crashing or unbounded")
    func deepNestingClamped() {
        let markdown = (0 ..< 20)
            .map { String(repeating: " ", count: $0 * 2) + "- level\($0)" }
            .joined(separator: "\n")
        let blocks = RichTextParser.parse(markdown)
        #expect(!blocks.isEmpty)
        #expect(RichTextProbe.maxListDepth(blocks) <= RichTextParser.maxListDepth + 1)
    }

    // MARK: - Inline hardening

    @Test("an https link stays tappable")
    func safeLinkKept() {
        let link = RichTextProbe.firstLink(RichTextParser.parse("see [docs](https://example.com/x)"))
        #expect(link?.absoluteString == "https://example.com/x")
    }

    @Test("a javascript: link is stripped of its link attribute")
    func unsafeLinkStripped() {
        let blocks = RichTextParser.parse("tap [here](javascript:alert(1))")
        #expect(RichTextProbe.firstLink(blocks) == nil)
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters).contains("here"))
    }

    @Test("malformed inline markdown falls back to raw text, never crashing")
    func malformedInline() {
        let blocks = RichTextParser.parse("a **bold that never closes")
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters).contains("bold that never closes"))
    }

    @Test("inline bold is applied within a paragraph")
    func inlineBold() {
        let attributed = InlineMarkdown.render("this is **bold** here")
        #expect(RichTextProbe.hasBold(attributed))
        #expect(String(attributed.characters) == "this is bold here")
    }
}
