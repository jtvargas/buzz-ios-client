import Foundation
@testable import Hive
import Testing

/// GFM pipe tables: what counts as one, how a row splits into cells, and the two rules
/// that exist so a table never costs the reader text — a widened table rather than
/// truncated rows, and a plain-text fallback rather than a half-drawn grid.
@Suite("Rich text tables")
struct RichTextTableTests {
    // MARK: - Recognition

    @Test("a header, a delimiter row and a body row make a table")
    func simpleTable() {
        guard case let .table(table) = RichTextParser.parse(
            "| env | boxes |\n| --- | --- |\n| prod | 9 |"
        ).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.columnCount == 2)
        #expect(table.header.map { String($0.characters) } == ["env", "boxes"])
        #expect(table.rows.map { $0.map { String($0.characters) } } == [["prod", "9"]])
    }

    @Test("outer pipes are optional, as GFM says")
    func noOuterPipes() {
        guard case .table = RichTextParser.parse("env | boxes\n--- | ---\nprod | 9").first else {
            Issue.record("expected a table")
            return
        }
    }

    @Test("two pipe rows with no delimiter stay a paragraph, keeping every cell")
    func noDelimiterKeepsText() {
        // Upstream draws this as a one-row table and drops the second line entirely.
        // Text on screen beats a border around half of it.
        let blocks = RichTextParser.parse("| staging | prod |\n| 3 boxes | 9 boxes |")
        guard case let .paragraph(text) = blocks.first else {
            Issue.record("expected a paragraph")
            return
        }
        #expect(String(text.characters).contains("3 boxes"))
        #expect(String(text.characters).contains("9 boxes"))
    }

    @Test("a delimiter row of the wrong width does not open a table")
    func mismatchedDelimiter() {
        let blocks = RichTextParser.parse("totals | 2024\n---")
        #expect(!blocks.contains { if case .table = $0 { true } else { false } })
    }

    @Test("a single dash is a valid delimiter cell")
    func singleDashDelimiter() {
        guard case .table = RichTextParser.parse("| a | b |\n| - | - |\n| 1 | 2 |").first else {
            Issue.record("expected a table")
            return
        }
    }

    @Test("the table ends at a blank line and what follows parses on its own")
    func tableEndsAtBlankLine() {
        let blocks = RichTextParser.parse("| a |\n| --- |\n| 1 |\n\nafter")
        #expect(blocks.count == 3)
        if case .table = blocks[0] {} else { Issue.record("block 0 table") }
        #expect(blocks[1] == .sourceBlankLine)
        guard case let .paragraph(text) = blocks[2] else {
            Issue.record("block 2 paragraph")
            return
        }
        #expect(String(text.characters) == "after")
    }

    @Test("a fence directly under a table ends it rather than becoming a row")
    func tableEndsAtFence() {
        let blocks = RichTextParser.parse("| a |\n| --- |\n| 1 |\n```\ncode\n```")
        #expect(blocks.count == 2)
        if case .table = blocks[0] {} else { Issue.record("block 0 table") }
        #expect(blocks[1] == .code("code", info: nil))
    }

    // MARK: - Alignment

    @Test("colons in the delimiter row set each column's alignment")
    func alignments() {
        guard case let .table(table) = RichTextParser.parse(
            "| l | c | r | d |\n| :-- | :-: | --: | --- |\n| 1 | 2 | 3 | 4 |"
        ).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.leading, .center, .trailing, .leading])
    }

    // MARK: - Cell splitting

    @Test("an escaped pipe stays inside its cell")
    func escapedPipe() {
        #expect(RichTextParser.tableCells(#"| ps \| grep swift | runs |"#) == ["ps | grep swift", "runs"])
    }

    @Test("an empty middle cell survives, so later cells keep their column")
    func emptyMiddleCell() {
        // Upstream drops every empty cell, which slides `c` under `b`'s heading.
        #expect(RichTextParser.tableCells("| a | | c |") == ["a", "", "c"])
    }

    @Test("only the empty cell an outer pipe makes is dropped")
    func trailingEmptyCellKept() {
        #expect(RichTextParser.tableCells("|a|b||") == ["a", "b", ""])
    }

    @Test("a line with no pipe is not a row at all")
    func noPipeIsNotARow() {
        #expect(RichTextParser.tableCells("plain text") == nil)
    }

    // MARK: - Shape

    @Test("a row wider than the header widens the table instead of losing cells")
    func widerRowWidensTable() {
        guard case let .table(table) = RichTextParser.parse(
            "| a | b |\n| --- | --- |\n| 1 | 2 | 3 |"
        ).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.columnCount == 3)
        #expect(table.rows[0].map { String($0.characters) } == ["1", "2", "3"])
        // The header grew a nameless column rather than the row losing a cell.
        #expect(table.header.count == 3)
    }

    @Test("a short row is padded so every row has the same cell count")
    func shortRowPadded() {
        guard case let .table(table) = RichTextParser.parse(
            "| a | b | c |\n| --- | --- | --- |\n| 1 |"
        ).first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows[0].count == 3)
        #expect(table.alignments.count == 3)
    }

    @Test("a table past the cell budget renders as plain text, complete")
    func oversizeTableFallsBackToText() {
        var lines = ["| a | b |", "| --- | --- |"]
        // Two columns, so the budget is exceeded once the body passes 599 rows.
        for row in 0 ..< 600 { lines.append("| r\(row) | v\(row) |") }
        let blocks = RichTextParser.parse(lines.joined(separator: "\n"))

        #expect(!blocks.contains { if case .table = $0 { true } else { false } })
        let text = blocks.map { String(RichTextProbe.inline(of: $0).characters) }.joined()
        #expect(text.contains("r0"))
        #expect(text.contains("v599"))
    }

    // MARK: - Inline content

    @Test("a mention inside a cell resolves like one in a paragraph")
    func entitiesReachCells() {
        let resolver = StubMentionResolver(members: ["Ada": MentionMatch(pubkey: "pk", isSelf: false)])
        let message = RichMessage.make("| who | role |\n| --- | --- |\n| @Ada | lead |", resolver: resolver)

        guard case let .table(table) = message.blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(RichTextProbe.firstMention(table.rows[0][0])?.pubkey == "pk")
    }

    @Test("a bare URL inside a cell is autolinked like one in a paragraph")
    func autolinkReachesCells() {
        let message = RichMessage.make(
            "| doc |\n| --- |\n| https://example.com/x |",
            resolver: StubMentionResolver()
        )
        guard case let .table(table) = message.blocks.first else {
            Issue.record("expected a table")
            return
        }
        #expect(table.rows[0][0].runs.compactMap(\.link).first?.absoluteString == "https://example.com/x")
    }

    @Test("a table's cells reach the one-line snippet")
    func tableFlattensIntoSnippet() {
        let message = RichMessage.make("| env | boxes |\n| --- | --- |\n| prod | 9 |", resolver: StubMentionResolver())
        let flat = String(message.flattenedInline().characters)
        #expect(flat == "env boxes prod 9")
    }
}
