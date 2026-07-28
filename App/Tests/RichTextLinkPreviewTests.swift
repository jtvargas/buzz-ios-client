import Foundation
@testable import Hive
import Testing

/// Which of a message's links become cards, in what order, and — mostly — which do not.
///
/// The exclusions are the point of the suite. A card is drawn from a *link run*, so
/// everything the earlier stages refuse to link is already excluded; these are what would
/// catch that stopping being true, on the surface where it matters most (a URL in a
/// pasted shell transcript is exactly the URL nobody wants unfurled).
@Suite("Rich text link previews")
struct RichTextLinkPreviewTests {
    private func blocks(_ text: String) -> [RichBlock] {
        RichMessage.make(text, resolver: StubMentionResolver()).blocks
    }

    private func previewCards(_ text: String) -> [LinkPreview] {
        blocks(text).compactMap { block in
            guard case let .linkPreview(preview) = block else { return nil }
            return preview
        }
    }

    // MARK: - Placement

    @Test("a card is appended after the message's own blocks")
    func cardsComeLast() throws {
        let parsed = blocks("shipped it\n\nhttps://github.com/o/r/pull/61")

        #expect(parsed.count == 3)
        if case .linkPreview = parsed[0] { Issue.record("a card came before the message") }
        if case .linkPreview = parsed[1] { Issue.record("a card came before the message") }
        guard case let .linkPreview(preview) = parsed[2] else {
            Issue.record("the last block is not a card")
            return
        }
        #expect(preview.title == "o/r #61")
    }

    /// The card is a *second* rendering of the link. The link itself stays exactly where
    /// it was typed, still pressable, because removing it would edit the author's sentence.
    @Test("the link stays in the text it was written in")
    func linkStaysInText() throws {
        let parsed = blocks("see https://example.com/docs for the rest")

        guard case let .paragraph(text) = parsed[0] else {
            Issue.record("the message's first block is not its paragraph")
            return
        }
        #expect(String(text.characters) == "see https://example.com/docs for the rest")
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com/docs" })
    }

    @Test("a message with no links gets no cards")
    func noLinks() throws {
        #expect(previewCards("just words, and an @mention").isEmpty)
    }

    // MARK: - Order, de-duplication, and the cap

    @Test("cards follow the order their links first appear")
    func readingOrder() throws {
        let found = previewCards(
            """
            # https://example.com/one

            - https://example.com/two
            - https://example.com/three
            """
        )

        #expect(found.map(\.title) == ["/one", "/two", "/three"])
    }

    @Test("one URL written twice is one card")
    func duplicateURL() throws {
        #expect(previewCards("https://example.com/a and again https://example.com/a").count == 1)
    }

    /// The shape that actually occurs: named in the sentence, then pasted on its own
    /// line. One card, and the author's own words as its title.
    @Test("a link named once and pasted again is one card, titled by the label")
    func duplicateAcrossLabelAndBareURL() throws {
        let found = previewCards("[the scroll fix](https://github.com/o/r/pull/1)\n\nhttps://github.com/o/r/pull/1")

        #expect(found.count == 1)
        #expect(found.first?.title == "the scroll fix")
    }

    @Test("no more cards than the cap, however many links a message has")
    func cap() throws {
        let links = (1 ... 10).map { "https://example.com/\($0)" }.joined(separator: "\n\n")

        #expect(previewCards(links).count == RichTextLinkPreview.maximumCards)
    }

    // MARK: - What earns no card

    @Test("a URL inside a code span is not previewed")
    func codeSpan() throws {
        #expect(previewCards("run `curl https://example.com/api` first").isEmpty)
    }

    @Test("a URL inside a fenced block is not previewed")
    func fencedBlock() throws {
        #expect(previewCards("```\ncurl https://example.com/api\n```").isEmpty)
    }

    @Test("a mention and an internal message link are not previewed")
    func internalLinks() throws {
        #expect(previewCards("@someone see buzz://message?channel=abc&id=def").isEmpty)
    }

    @Test("an email address is not previewed")
    func email() throws {
        #expect(previewCards("write to someone@example.com").isEmpty)
    }

    // MARK: - Titles

    @Test("an authored label becomes the card's title")
    func authoredLabel() throws {
        let found = previewCards("[The scroll fix](https://github.com/o/r/pull/61)")

        #expect(found.first?.title == "The scroll fix")
        #expect(found.first?.caption == "GitHub · PR") // still says what it is
    }

    /// An autolinked URL's "label" is the URL. Taking it as a title would print the link
    /// twice on a two-line card and say nothing either time.
    @Test("a label that is only the URL again is not a title")
    func labelThatIsTheURL() throws {
        let link = "https://github.com/o/r/pull/61"

        #expect(previewCards("[\(link)](\(link))").first?.title == "o/r #61")
    }

    @Test("a label split by emphasis is joined back into one title")
    func labelAcrossRuns() throws {
        #expect(previewCards("[the **scroll** fix](https://example.com/a)").first?.title == "the scroll fix")
    }
}
