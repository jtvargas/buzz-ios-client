@testable import BuzzKit
import Foundation
import Testing

/// What a message's `imeta` tags (NIP-92) resolve to, and — as much as anything —
/// what they deliberately do *not*.
///
/// The dropping cases carry the weight here. A tag this refuses becomes a plain link
/// in the message text rather than an attachment, so "dropped" has to mean "not
/// media", never "lost" — which is the one thing a reader would notice.
@Suite("Message media from imeta", .timeLimit(.minutes(1)))
struct MessageMediaTests {
    private func imeta(_ fields: String...) -> [String] {
        ["imeta"] + fields
    }

    // MARK: - What is carried

    @Test("a full tag yields every field, and the URL is the identity")
    func fullTag() throws {
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/a.png", "m image/png", "dim 800x600", "alt A wide screenshot"),
        ])
        #expect(media.count == 1)
        // `#require` rather than an optional chain: every expectation below reads through
        // this value, and on `nil` a chained `one?.url == …` is false-but-not-failing in
        // some of them and silently skipped in the rest — an empty result would read as a
        // pass for the one test that checks the most.
        let one = try #require(media.first)
        #expect(one.url == "https://example.com/a.png")
        #expect(one.kind == .image)
        #expect(one.mimeType == "image/png")
        #expect(one.pixelSize == CGSize(width: 800, height: 600))
        #expect(one.alt == "A wide screenshot")
        #expect(one.id == one.url)
    }

    @Test("a value may contain spaces — only the first one separates")
    func valueKeepsItsSpaces() {
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/a.png", "alt two words and more"),
        ])
        #expect(media.first?.alt == "two words and more")
    }

    @Test("order is the order the tags declare")
    func declarationOrder() {
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/1.png"),
            imeta("url https://example.com/2.png"),
        ])
        #expect(media.map(\.url) == ["https://example.com/1.png", "https://example.com/2.png"])
    }

    @Test("the same URL twice in one message is one attachment")
    func duplicateURL() {
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/a.png", "alt first"),
            imeta("url https://example.com/a.png", "alt second"),
        ])
        #expect(media.count == 1)
        #expect(media.first?.alt == "first")
    }

    // MARK: - Classification

    @Test("the MIME type decides when the tag carries one", arguments: [
        ("image/png", MessageMediaKind.image),
        ("image/gif", .image),
        ("video/mp4", .video),
        ("application/octet-stream", .file),
        ("application/pdf", .file),
    ])
    func mimeDecides(type: String, expected: MessageMediaKind) {
        let media = MessageMedia.parse(tags: [imeta("url https://example.com/file", "m \(type)")])
        #expect(media.first?.kind == expected)
    }

    @Test("the path extension decides when there is no MIME type", arguments: [
        ("https://example.com/a.JPG", MessageMediaKind.image),
        ("https://example.com/a.webp", .image),
        ("https://example.com/a.mp4", .video),
    ])
    func extensionDecides(url: String, expected: MessageMediaKind) {
        #expect(MessageMedia.parse(tags: [imeta("url \(url)")]).first?.kind == expected)
    }

    @Test("a query string does not make an extension unrecognisable")
    func extensionBehindAQuery() {
        let media = MessageMedia.parse(tags: [imeta("url https://example.com/a.png?width=64&v=2")])
        #expect(media.first?.kind == .image)
    }

    @Test("a declared video this app cannot play is carried as a generic file")
    func unplayableVideoBecomesAFile() {
        // The extension says mp4 and the author says quicktime. The author wins: this
        // is the one place a fallback to the path would be second-guessing the tag.
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/a.mp4", "m video/quicktime"),
        ])
        #expect(media.first?.kind == .file)
    }

    // MARK: - Validation

    @Test("a tag with no usable URL is dropped", arguments: [
        ["imeta"],
        ["imeta", "m image/png"],
        ["imeta", "url "],
    ])
    func noURL(tag: [String]) {
        #expect(MessageMedia.parse(tags: [tag]).isEmpty)
    }

    @Test("imeta licenses an unclassifiable URL as a file without changing URL-only classification")
    func unclassifiable() {
        let url = "https://example.com/a.bin"
        #expect(MessageMediaKind(url: url) == nil)
        #expect(MessageMedia.parse(tags: [imeta("url \(url)")]).first?.kind == .file)
    }

    @Test("a generic file carries its sender-visible name and nonnegative byte count")
    func fileMetadata() throws {
        let media = MessageMedia.parse(tags: [
            imeta(
                "url https://example.com/a.bin",
                "m application/octet-stream",
                "size 328",
                "filename addresses.csv"
            ),
        ])

        let file = try #require(media.first)
        #expect(file.kind == .file)
        #expect(file.filename == "addresses.csv")
        #expect(file.byteCount == 328)
    }

    @Test("an invalid file size is absent")
    func invalidFileSize() {
        let media = MessageMedia.parse(tags: [
            imeta("url https://example.com/a.pdf", "m application/pdf", "size -1"),
        ])
        #expect(media.first?.byteCount == nil)
    }

    @Test("tags that are not imeta are ignored")
    func otherTags() {
        let media = MessageMedia.parse(tags: [
            ["e", "abc", "", "root"],
            ["p", "def"],
            imeta("url https://example.com/a.png"),
        ])
        #expect(media.count == 1)
    }

    @Test("a field with no separating space is skipped, not misread")
    func malformedField() {
        let media = MessageMedia.parse(tags: [imeta("url https://example.com/a.png", "dim", "alt ok")])
        #expect(media.first?.pixelSize == nil)
        #expect(media.first?.alt == "ok")
    }

    // MARK: - Dimensions, which reserve the row's space

    @Test("dimensions become an aspect ratio")
    func aspectRatio() {
        let media = MessageMedia.parse(tags: [imeta("url https://example.com/a.png", "dim 800x400")])
        #expect(media.first?.aspectRatio == 2)
    }

    @Test("a dimension that cannot reserve space yields none rather than a broken one", arguments: [
        "0x600", "800x0", "-800x600", "800", "800x600x2", "widexhigh", "",
    ])
    func unusableDimensions(dim: String) {
        // A zero or negative extent divides into an infinity or a negative height, and a
        // frame built from either is a layout the conversation does not recover from.
        let media = MessageMedia.parse(tags: [imeta("url https://example.com/a.png", "dim \(dim)")])
        #expect(media.first?.aspectRatio == nil)
    }
}
