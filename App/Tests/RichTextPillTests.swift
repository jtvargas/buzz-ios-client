import Foundation
@testable import Hive
import Testing

/// The pill geometry the renderer draws, as values: `Text.Layout.Line` cannot be built
/// in a test, so the merge rule is separated from the draw that applies it — together
/// with the kerning that holds a pill off the text beside it.
@Suite("Rich text pills")
struct RichTextPillTests {
    private func rect(_ originX: CGFloat, width: CGFloat) -> CGRect {
        CGRect(x: originX, y: 0, width: width, height: 20)
    }

    private func run(_ key: String?, _ rect: CGRect, advance: CGFloat = 0) -> RichTextEntityRenderer.Run {
        RichTextEntityRenderer.Run(key: key, trailingAdvance: advance, rect: rect)
    }

    private func inline(_ text: String, _ resolver: MentionResolver) -> AttributedString {
        RichTextProbe.inline(of: RichMessage.make(text, resolver: resolver).blocks[0])
    }

    /// Every run carrying kerning, as `(text, amount)` — the advance that holds a pill
    /// off the text beside it.
    private func kerned(_ attributed: AttributedString) -> [(text: String, kern: CGFloat)] {
        attributed.runs.compactMap { run in
            guard let kern = run.kern else { return nil }
            return (String(attributed[run.range].characters), kern)
        }
    }

    // MARK: - Merging

    @Test("adjacent runs of one mention merge into a single pill")
    func adjacentRunsMerge() {
        // `@**Ada** Lovelace`: three layout runs, one range, one pill — three fills
        // would overlap their padding and show as brighter seams around the bold word.
        let merged = RichTextEntityRenderer.merged([
            run("ada", rect(0, width: 10)),
            run("ada", rect(10, width: 30)),
            run("ada", rect(40, width: 50)),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].rect == rect(0, width: 90))
    }

    @Test("two references to the same person on one line stay two pills")
    func repeatedKeyDoesNotMergeAcrossText() {
        let merged = RichTextEntityRenderer.merged([
            run("ada", rect(0, width: 40)),
            run(nil, rect(40, width: 60)),
            run("ada", rect(100, width: 40)),
        ])
        #expect(merged.count == 2)
        #expect(merged.map(\.rect.width) == [40, 40])
    }

    @Test("two different entities side by side are two pills")
    func differentKeysDoNotMerge() {
        let merged = RichTextEntityRenderer.merged([
            run("ada", rect(0, width: 40)),
            run("will", rect(40, width: 40)),
        ])
        #expect(merged.count == 2)
    }

    @Test("a line with nothing interactive has no pills")
    func noPills() {
        #expect(RichTextEntityRenderer.merged([run(nil, rect(0, width: 100))]).isEmpty)
    }

    // MARK: - The gap beside a pill

    @Test("the gap's advance is not part of the pill it sits beside")
    func trailingAdvanceIsNotFilled() {
        // The last character's typographic bounds include the kern added after it
        // (measured in a harness), so the fill would otherwise reach over the gap and
        // straight back onto the neighbouring glyph.
        let gap = RichTextStyle.pillAdvance
        let merged = RichTextEntityRenderer.merged([
            run("ada", rect(0, width: 40)),
            run("ada", rect(40, width: 10 + gap), advance: gap),
        ])
        #expect(merged.count == 1)
        #expect(merged[0].rect == rect(0, width: 50))
    }

    @Test("a range that wraps keeps a full-width fill on the line it does not end on")
    func wrappedRangeIsNotTrimmedEarly() {
        // Only the range's final character carries the advance, so the first line of a
        // wrapped link fills to the end of its glyphs rather than stopping short.
        let merged = RichTextEntityRenderer.merged([run("url", rect(0, width: 120))])
        #expect(merged.map(\.rect.width) == [120])
    }

    @Test("a mention is kerned away from the text on both sides of it")
    func mentionIsSpacedFromItsNeighbours() {
        let resolver = StubMentionResolver(members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)])
        let styled = RichTextStyle.styled(inline("hi @ada!", resolver), base: .body, interactive: true)
        let spaced = kerned(styled)
        // The character *before* the mention and the mention's own last character: the
        // only two places advance can be added, since a glyph has no leading bearing.
        #expect(spaced.map(\.text) == [" ", "a"])
        #expect(spaced.allSatisfy { $0.kern == RichTextStyle.pillAdvance })
    }

    @Test("a mention split by emphasis is spaced at its ends, never inside it")
    func emphasisDoesNotOpenAGapInsideAPill() {
        let resolver = StubMentionResolver(members: ["ada lovelace": MentionMatch(pubkey: "PK", isSelf: false)])
        let styled = RichTextStyle.styled(
            inline("hi @**ada** lovelace!", resolver),
            base: .body,
            interactive: true
        )
        // Three runs, one pill: kerning each run's last character would open gaps
        // through the middle of the mention.
        #expect(kerned(styled).map(\.text) == [" ", "e"])
    }

    @Test("a message that opens with a mention is spaced only after it")
    func leadingMentionHasNothingToBeSpacedFrom() {
        let resolver = StubMentionResolver(members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)])
        let styled = RichTextStyle.styled(inline("@ada hi", resolver), base: .body, interactive: true)
        #expect(kerned(styled).map(\.text) == ["a"])
    }

    @Test("spacing a mention splits its last character off, still carrying the link")
    func spacingSplitsTheLastRunButNotTheLink() {
        // The kern is an attribute, so the character carrying it becomes a run of its
        // own. Both halves keep the same link, and ``RichTextSegments`` puts them back
        // together — which is why one mention is still one pill and one hit target.
        let resolver = StubMentionResolver(members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)])
        let styled = RichTextStyle.styled(inline("hi @ada!", resolver), base: .body, interactive: true)
        let linked = styled.runs.filter { $0.link != nil }
        #expect(linked.count == 2)
        #expect(Set(linked.compactMap(\.link)).count == 1)

        let segments = RichTextSegments.segments(of: styled).filter { $0.link != nil }
        #expect(segments.count == 1)
        #expect(String(styled[segments[0].range].characters) == "@ada")
    }

    @Test("a one-line preview is not kerned, because it draws no pill")
    func snippetIsNotSpaced() {
        let resolver = StubMentionResolver(members: ["ada": MentionMatch(pubkey: "PK_ADA", isSelf: false)])
        let styled = RichTextStyle.styled(inline("hi @ada!", resolver), base: .body, interactive: false)
        #expect(kerned(styled).isEmpty)
    }
}
