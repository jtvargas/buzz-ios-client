import Foundation
@testable import Hive
import Testing

/// The rich-content markdown parser and its hardening: block classification, the
/// CommonMark subset the workspace uses, and unsafe-link stripping. Pure and
/// deterministic — no store, no view.
@Suite("Message content parsing")
struct MessageContentTests {
    // MARK: - Blocks

    @Test("plain text is one paragraph")
    func plainParagraph() {
        let blocks = MessageContent.parse("just a line of text")
        #expect(blocks == [.paragraph(AttributedString("just a line of text"))])
    }

    @Test("empty content yields no blocks")
    func emptyContent() {
        #expect(MessageContent.parse("").isEmpty)
    }

    @Test("a hash-prefixed line is a heading at its level")
    func heading() {
        guard case let .heading(level, text) = MessageContent.parse("## Section").first else {
            Issue.record("expected a heading")
            return
        }
        #expect(level == 2)
        #expect(String(text.characters) == "Section")
    }

    @Test("more than six hashes is not a heading")
    func tooManyHashes() {
        let blocks = MessageContent.parse("####### not a heading")
        #expect(blocks.count == 1)
        if case .heading = blocks[0] { Issue.record("should not be a heading") }
    }

    @Test("a hash with no space is not a heading")
    func hashWithoutSpace() {
        let blocks = MessageContent.parse("#hashtag not a heading")
        if case .heading = blocks.first { Issue.record("should not be a heading") }
    }

    @Test("dash, star, and plus all start bullet items")
    func bulletList() {
        let blocks = MessageContent.parse("- one\n* two\n+ three")
        guard case let .bulletList(items) = blocks.first else {
            Issue.record("expected a bullet list")
            return
        }
        #expect(items.map { String($0.characters) } == ["one", "two", "three"])
    }

    @Test("numbered lines form an ordered list")
    func orderedList() {
        let blocks = MessageContent.parse("1. first\n2) second")
        guard case let .orderedList(items) = blocks.first else {
            Issue.record("expected an ordered list")
            return
        }
        #expect(items.map { String($0.characters) } == ["first", "second"])
    }

    @Test("a fenced code block keeps its raw text and language, unparsed")
    func fencedCode() {
        let blocks = MessageContent.parse("```swift\nlet x = *notBold*\n```")
        #expect(blocks == [.code("let x = *notBold*", language: "swift")])
    }

    @Test("an unterminated fence runs to the end of the message")
    func unterminatedFence() {
        let blocks = MessageContent.parse("```\ncode line 1\ncode line 2")
        #expect(blocks == [.code("code line 1\ncode line 2", language: nil)])
    }

    @Test("a > line is a block quote")
    func blockQuote() {
        let blocks = MessageContent.parse("> quoted words")
        guard case let .quote(text) = blocks.first else {
            Issue.record("expected a quote")
            return
        }
        #expect(String(text.characters) == "quoted words")
    }

    @Test("a mixed document parses into the expected block sequence")
    func mixedDocument() {
        let blocks = MessageContent.parse("# Title\n\npara text\n\n- a\n- b\n\n```\ncode\n```")
        #expect(blocks.count == 4)
        if case .heading(1, _) = blocks[0] {} else { Issue.record("block 0 heading") }
        if case .paragraph = blocks[1] {} else { Issue.record("block 1 paragraph") }
        if case .bulletList = blocks[2] {} else { Issue.record("block 2 bullets") }
        if case .code = blocks[3] {} else { Issue.record("block 3 code") }
    }

    // MARK: - Inline hardening

    @Test("an https link stays tappable")
    func safeLinkKept() {
        let link = firstLink(in: MessageContent.parse("see [docs](https://example.com/x)"))
        #expect(link?.absoluteString == "https://example.com/x")
    }

    @Test("a javascript: link is stripped of its link attribute")
    func unsafeLinkStripped() {
        let blocks = MessageContent.parse("tap [here](javascript:alert(1))")
        // The visible text survives, but nothing is tappable.
        #expect(firstLink(in: blocks) == nil)
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters).contains("here"))
    }

    @Test("malformed inline markdown falls back to raw text, never crashing")
    func malformedInline() {
        // An unbalanced emphasis run must not blank the message.
        let blocks = MessageContent.parse("a **bold that never closes")
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters).contains("bold that never closes"))
    }

    @Test("inline bold is applied within a paragraph")
    func inlineBold() {
        let attributed = MessageContent.inline("this is **bold** here")
        let hasBold = attributed.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
        #expect(hasBold)
        #expect(String(attributed.characters) == "this is bold here")
    }

    // MARK: - Helpers

    private func firstLink(in blocks: [MessageBlock]) -> URL? {
        for block in blocks {
            guard case let .paragraph(text) = block else { continue }
            if let link = text.runs.compactMap(\.link).first { return link }
        }
        return nil
    }
}
