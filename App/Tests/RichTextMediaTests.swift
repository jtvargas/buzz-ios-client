import BuzzKit
import Foundation
@testable import Hive
import Testing

/// Where a message's pictures end up, what describes them, and the one thing the memo
/// must never do with them.
///
/// The positioning tests are the parity tests: both reference clients draw an attachment
/// at the markdown image its author wrote and use `imeta` only to describe the URL it
/// names. Anything that reads a URL out of an `imeta` tag and appends it to the message
/// renders a document nobody published, and these are what would catch it.
@Suite("Rich text media")
struct RichTextMediaTests {
    private static let picture = "https://relay.example/media/abc.png"
    private static let second = "https://relay.example/media/def.jpg"

    private func media(
        _ url: String = RichTextMediaTests.picture,
        kind: MessageMediaKind = .image,
        pixelSize: CGSize? = nil,
        alt: String? = nil
    ) -> MessageMedia {
        MessageMedia(url: url, kind: kind, pixelSize: pixelSize, alt: alt)
    }

    private func blocks(_ text: String, media: [MessageMedia] = []) -> [RichBlock] {
        RichMessage.make(text, media: media, resolver: StubMentionResolver()).blocks
    }

    /// The one attachment a single-picture block carries.
    private func attached(_ block: RichBlock?) -> MessageMedia? {
        guard case let .media(media) = block, media.count == 1 else { return nil }
        return media.first
    }

    /// Every attachment a (possibly grouped) media block carries, in reading order.
    private func attachedGroup(_ block: RichBlock?) -> [MessageMedia]? {
        guard case let .media(media) = block else { return nil }
        return media
    }

    // MARK: - The text places it

    @Test("a markdown image becomes a media block where it was written")
    func imageWhereItWasWritten() throws {
        let parsed = blocks(
            "before\n![a graph](\(Self.picture))\nafter",
            media: [media(pixelSize: CGSize(width: 1200, height: 800))]
        )

        #expect(parsed.count == 3)
        #expect(String(RichTextProbe.inline(of: parsed[0]).characters) == "before")
        #expect(attached(parsed[1])?.url == Self.picture)
        #expect(String(RichTextProbe.inline(of: parsed[2]).characters) == "after")
    }

    @Test("an image mid-sentence splits the paragraph around it")
    func imageMidSentence() throws {
        let parsed = blocks("look at ![this](\(Self.picture)) closely", media: [media()])

        #expect(parsed.count == 3)
        #expect(String(RichTextProbe.inline(of: parsed[0]).characters) == "look at")
        #expect(attached(parsed[1])?.url == Self.picture)
        #expect(String(RichTextProbe.inline(of: parsed[2]).characters) == "closely")
    }

    @Test("an attachment the text never places draws nothing")
    func unplacedAttachmentIsNotDrawn() {
        let parsed = blocks("no picture here", media: [media()])

        #expect(parsed.count == 1)
        #expect(attached(parsed[0]) == nil)
    }

    @Test("a caption-less upload is the media block and nothing else")
    func captionlessUpload() {
        let parsed = blocks("![image](\(Self.picture))", media: [media()])

        #expect(parsed.count == 1)
        #expect(attached(parsed[0])?.url == Self.picture)
    }

    @Test("two attachments with words between them stay two blocks, in order")
    func twoAttachmentsWithWordsBetween() {
        let parsed = blocks(
            "![image](\(Self.second))\nsaid the caption\n![image](\(Self.picture))",
            media: [media(), media(Self.second)]
        )

        #expect(parsed.compactMap { attached($0)?.url } == [Self.second, Self.picture])
    }

    // MARK: - Consecutive pictures fold into one group

    @Test("consecutive images with nothing between them fold into one group, in order")
    func consecutiveImagesFold() {
        let third = "https://relay.example/media/ghi.gif"
        let parsed = blocks(
            "![a](\(Self.second))\n![b](\(Self.picture))\n![c](\(third))",
            media: [media(), media(Self.second), media(third)]
        )

        #expect(parsed.count == 1)
        #expect(attachedGroup(parsed.first)?.map(\.url) == [Self.second, Self.picture, third])
    }

    @Test("two separate paragraphs of one image each still fold — nothing sits between them")
    func separateParagraphsStillFold() {
        // A blank line between two image-only paragraphs: two `RichBlock`s reach `group`
        // adjacent to each other because neither carries a caption of its own, which is
        // the same shape as one paragraph with a bare newline between its images.
        let parsed = blocks(
            "![a](\(Self.second))\n\n![b](\(Self.picture))",
            media: [media(), media(Self.second)]
        )

        #expect(parsed.count == 1)
        #expect(attachedGroup(parsed.first)?.map(\.url) == [Self.second, Self.picture])
    }

    @Test("a video never folds into a picture group")
    func videoDoesNotFold() {
        let clip = "https://relay.example/media/clip.mp4"
        let parsed = blocks(
            "![a](\(Self.picture))\n![b](\(clip))",
            media: [media(), media(clip, kind: .video)]
        )

        #expect(parsed.count == 2)
        #expect(attached(parsed[0])?.url == Self.picture)
        #expect(attached(parsed[1])?.url == clip)
    }

    @Test("one URL written twice is two pictures in the group, not one")
    func repeatedURLKeepsBothEntries() {
        // The reason ``MessageMediaGroupView`` and ``MessageMediaViewer`` identify their
        // cells by position: `split` emits one block per image *run*, so this group holds
        // two entries whose ``BuzzKit/MessageMedia/id`` — the URL — is the same string.
        // Identifying them by that id is a `ForEach` over duplicate ids, which SwiftUI
        // calls undefined, and would cost the gallery a page the reader cannot swipe to.
        let parsed = blocks(
            "![a](\(Self.picture))\n![a again](\(Self.picture))",
            media: [media()]
        )

        let group = attachedGroup(parsed.first)
        #expect(parsed.count == 1)
        #expect(group?.count == 2)
        #expect(group?.map(\.url) == [Self.picture, Self.picture])
        #expect(group?[0].id == group?[1].id)
    }

    // MARK: - A bare URL is a link, not a picture

    @Test("a bare media URL stays a link, as it does in both reference clients")
    func bareURLStaysALink() throws {
        let parsed = blocks("see \(Self.picture)", media: [media()])

        #expect(parsed.count == 1)
        let inline = RichTextProbe.inline(of: parsed[0])
        #expect(String(inline.characters) == "see \(Self.picture)")
        #expect(inline.runs.contains { $0.link?.absoluteString == Self.picture })
    }

    @Test("a placed picture is not also a link beside itself")
    func placedPictureIsNotAlsoALink() {
        // The alt text is the URL, which is the shape that would leave a link behind:
        // autolinking runs after the lift, so those characters are gone before it looks.
        let parsed = blocks("![\(Self.picture)](\(Self.picture))", media: [media()])

        #expect(parsed.count == 1)
        #expect(attached(parsed[0])?.url == Self.picture)
    }

    // MARK: - imeta describes

    @Test("the matching imeta entry supplies the size the layout reserves")
    func imetaSuppliesTheReservation() throws {
        let parsed = blocks(
            "![image](\(Self.picture))",
            media: [media(pixelSize: CGSize(width: 1600, height: 900), alt: "the release chart")]
        )

        let attachment = try #require(attached(parsed.first))
        // The declared size, which is what the reservation is actually built from and is
        // exact: two integers that survive the round trip without arithmetic.
        #expect(attachment.pixelSize == CGSize(width: 1600, height: 900))
        #expect(attachment.alt == "the release chart")

        // The ratio to a tolerance rather than `== 16.0 / 9.0`. That exact comparison
        // held locally — `1600.0 / 900.0` and `16.0 / 9.0` are bit-identical here under
        // both `-Onone` and `-O`, compared by `bitPattern` — and failed twice on CI on
        // this same commit, printing two values whose descriptions were character for
        // character the same. I could not account for that difference, and an equality
        // that depends on it was never the property worth pinning: a reservation cannot
        // be a unit in the seventeenth significant digit wrong.
        let ratio = try #require(attachment.aspectRatio)
        #expect(abs(ratio - 16.0 / 9.0) < 0.000_001)
    }

    @Test("an entry naming a different URL describes nothing")
    func mismatchedURLDescribesNothing() throws {
        let parsed = blocks(
            "![image](\(Self.picture))",
            media: [media(Self.second, pixelSize: CGSize(width: 100, height: 50))]
        )

        let attachment = try #require(attached(parsed.first))
        #expect(attachment.url == Self.picture)
        #expect(attachment.aspectRatio == nil)
    }

    @Test("an undescribed image node is still drawn, classified from its URL")
    func undescribedNodeIsStillMedia() throws {
        let parsed = blocks("![clip](https://elsewhere.example/clip.mp4)")

        let attachment = try #require(attached(parsed.first))
        #expect(attachment.kind == .video)
        #expect(attachment.aspectRatio == nil)
    }

    @Test("a URL nothing can classify is an image, because the author wrote one")
    func unclassifiableNodeIsAnImage() throws {
        let parsed = blocks("![a photo](https://elsewhere.example/download)")

        #expect(attached(parsed.first)?.kind == .image)
    }

    // MARK: - Alt text

    @Test("the tag's alt wins over the composer's placeholder")
    func tagAltWins() throws {
        let parsed = blocks("![image](\(Self.picture))", media: [media(alt: "a wide screenshot")])

        #expect(attached(parsed.first)?.alt == "a wide screenshot")
    }

    @Test("the author's alt is kept when the tag carries none")
    func authoredAltKept() throws {
        let parsed = blocks("![the office dog](\(Self.picture))", media: [media()])

        #expect(attached(parsed.first)?.alt == "the office dog")
    }

    @Test("an empty alt is no alt, not a replacement character")
    func emptyAltIsNil() throws {
        let parsed = blocks("![](\(Self.picture))", media: [media()])

        #expect(attached(parsed.first)?.alt == nil)
    }

    // MARK: - Blocks that keep their images inline

    @Test("a quote is not split around an image it contains")
    func quoteKeepsItsImage() {
        let parsed = blocks("> quoting ![a picture](\(Self.picture))", media: [media()])

        #expect(parsed.count == 1)
        #expect(attached(parsed[0]) == nil)
    }

    @Test("a fenced code block's image syntax is text, as it always was")
    func codeKeepsItsImageSyntax() {
        let parsed = blocks("```\n![image](\(Self.picture))\n```", media: [media()])

        #expect(parsed == [.code("![image](\(Self.picture))", language: nil)])
    }

    // MARK: - Spacing and snippets

    @Test("media takes the gap a framed block takes, on both sides")
    func mediaSpacing() {
        let text = RichBlock.paragraph(AttributedString("words"))
        let picture = RichBlock.media([media()])

        #expect(RichTextSpacing.gap(after: text, before: picture) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.gap(after: picture, before: text) == RichTextSpacing.aroundBoxed)
        #expect(RichTextSpacing.gap(after: picture, before: picture) == RichTextSpacing.aroundBoxed)
    }

    @Test("a picture-only message previews as what it is rather than as nothing")
    func snippetNamesTheAttachment() {
        let message = RichMessage.make(
            "![image](\(Self.picture))",
            media: [media(alt: "a very long description that would fill the whole line")],
            resolver: StubMentionResolver()
        )

        #expect(String(message.flattenedInline().characters) == "Image")
    }

    @Test("a captioned picture previews as its caption and its kind")
    func snippetKeepsTheWords() {
        let message = RichMessage.make(
            "the new logo\n![image](\(Self.picture))",
            media: [media()],
            resolver: StubMentionResolver()
        )

        #expect(String(message.flattenedInline().characters) == "the new logo Image")
    }

    // MARK: - The memo

    @MainActor
    @Test("two messages with the same text and different pictures do not share a memo entry")
    func memoDoesNotCollideOnMedia() throws {
        RichMessageCache.removeAll()
        let resolver = StubMentionResolver(identity: "resolver")
        // What a composer writes for every upload: identical bodies, different photographs.
        let text = "![image](\(Self.picture))"

        let first = RichMessageCache.message(for: text, media: [media()], resolver: resolver)
        let other = RichMessageCache.message(
            for: text.replacingOccurrences(of: Self.picture, with: Self.second),
            media: [media(Self.second)],
            resolver: resolver
        )

        #expect(attached(first.blocks.first)?.url == Self.picture)
        #expect(attached(other.blocks.first)?.url == Self.second)
    }

    @MainActor
    @Test("the same text and the same URL re-parse when the description changes")
    func memoDoesNotCollideOnDescription() throws {
        RichMessageCache.removeAll()
        let resolver = StubMentionResolver(identity: "resolver")
        let text = "![image](\(Self.picture))"

        // An edit can republish the same body with a different `imeta` — a re-crop keeps
        // the URL and changes the size the row reserves.
        let tall = RichMessageCache.message(
            for: text,
            media: [media(pixelSize: CGSize(width: 400, height: 800))],
            resolver: resolver
        )
        let wide = RichMessageCache.message(
            for: text,
            media: [media(pixelSize: CGSize(width: 800, height: 400))],
            resolver: resolver
        )

        #expect(attached(tall.blocks.first)?.aspectRatio == 0.5)
        #expect(attached(wide.blocks.first)?.aspectRatio == 2)
    }

    @MainActor
    @Test("a message with no attachments still returns the value it cached")
    func memoStillServesPlainText() {
        RichMessageCache.removeAll()
        let resolver = StubMentionResolver(identity: "resolver")

        let first = RichMessageCache.message(for: "plain words", resolver: resolver)
        let second = RichMessageCache.message(for: "plain words", resolver: resolver)

        #expect(first == second)
    }
}
