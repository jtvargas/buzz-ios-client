import BuzzKit
import Foundation

/// The media stage: lifts the pictures a message *places* out of its paragraphs and into
/// ``RichBlock/media(_:)`` blocks, describing each from the `imeta` tag that names the
/// same URL.
///
/// # Where an attachment goes, and who decides
///
/// The message text decides; `imeta` only describes. Both reference clients work this
/// way and it is worth being precise about it, because the obvious alternative —
/// appending every `imeta` attachment to the end of the message — renders a different
/// document from the one the author wrote.
///
/// - The Flutter client hands its markdown renderer an `imageBuilder`, called once per
///   markdown image node, and looks the node's URL up in a map built from the `imeta`
///   tags. A tag naming a URL the text never mentions draws nothing at all.
/// - Its composer is the other half of that contract: an upload appends
///   `![image](url)` to the body *and* emits the matching `imeta` tag. The Tauri client
///   does the same and says why in as many words — its renderer "only renders
///   `<img>`/`<video>` for URLs literally present in the body".
///
/// So an attachment is drawn where its URL appears, and a bare `https://…/a.png` typed
/// into a sentence stays a link: neither client promotes one to a picture, and both
/// autolink it instead. That is why nothing here looks at the message's URLs — only at
/// its image *nodes*.
///
/// # Why this runs before autolinking
///
/// An image node reaches here as its alt text carrying a `imageURL` attribute
/// (Foundation's markdown parser resolves `![alt](url)` that way). Lifting it out first
/// removes those characters from the paragraph before ``RichTextAutolink`` and
/// ``RichTextEntities`` ever see them — so a picture can never also appear as a link or
/// a mention beside itself, which is the duplication this ordering exists to prevent.
enum RichTextMedia {
    /// `blocks` with every markdown image lifted into its own media block, described by
    /// whichever of `media` names the same URL.
    ///
    /// Only paragraphs are opened up. A heading, a quote, a list item or a table cell
    /// keeps an image as the alt text it already renders as: those blocks are one
    /// `AttributedString` each by construction, and splitting a quote in three around a
    /// picture would draw two quotes where the author wrote one. Neither reference
    /// client's composer can author that shape, so what is given up is a hand-written
    /// message from another editor, rendered as its own alt text rather than wrongly.
    static func lift(_ blocks: [RichBlock], describedBy media: [MessageMedia]) -> [RichBlock] {
        // Keyed by URL because that is what an image node has to look itself up by, and
        // because `imeta` is keyed by URL in the first place. First wins on a repeat,
        // matching ``MessageMedia/parse(tags:)``, which already de-duplicates.
        let described = Dictionary(media.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let lifted = blocks.flatMap { block -> [RichBlock] in
            guard case let .paragraph(text) = block, carriesImage(text) else { return [block] }
            return split(text, describedBy: described)
        }
        return group(lifted)
    }

    /// `blocks` with adjacent `.media` entries — pictures the author placed with nothing
    /// between them, whether from one split paragraph or from two consecutive ones —
    /// folded into a single ``RichBlock/media(_:)`` the renderer draws as a mosaic.
    ///
    /// Videos never fold: there is no gallery to page a placeholder into, and mixing one
    /// into a run of pictures would put an inert tile in a set every other member of
    /// which opens. Each stays the one-picture group ``MessageMediaGroupView`` already
    /// draws exactly as a lone attachment.
    private static func group(_ blocks: [RichBlock]) -> [RichBlock] {
        var result: [RichBlock] = []
        for block in blocks {
            guard case let .media(items) = block, items.allSatisfy({ $0.kind == .image }),
                  case .media(let previous)? = result.last, previous.last?.kind == .image
            else {
                result.append(block)
                continue
            }
            result[result.count - 1] = .media(previous + items)
        }
        return result
    }

    private static func carriesImage(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.imageURL != nil }
    }

    // MARK: - Splitting a paragraph

    /// One paragraph as the alternating text and media it turned out to be.
    ///
    /// The text either side of a picture is trimmed and dropped when nothing is left,
    /// because the shape a composer writes — a body, a newline, then `![image](url)` —
    /// is a single paragraph to the block parser (consecutive non-blank lines are one
    /// paragraph with its soft breaks kept). Without the trim every attachment would
    /// leave a blank line above it.
    private static func split(
        _ text: AttributedString,
        describedBy described: [String: MessageMedia]
    ) -> [RichBlock] {
        var blocks: [RichBlock] = []
        var pending = AttributedString()

        for run in text.runs {
            guard let imageURL = run.imageURL else {
                pending.append(text[run.range])
                continue
            }
            appendParagraph(pending, to: &blocks)
            pending = AttributedString()
            blocks.append(.media([describe(
                imageURL,
                alt: String(text[run.range].characters),
                by: described[imageURL.absoluteString]
            )]))
        }
        appendParagraph(pending, to: &blocks)
        return blocks
    }

    private static func appendParagraph(_ text: AttributedString, to blocks: inout [RichBlock]) {
        let trimmed = trimmed(text)
        guard !trimmed.characters.isEmpty else { return }
        blocks.append(.paragraph(trimmed))
    }

    /// `text` without its leading and trailing whitespace, attributes intact.
    ///
    /// Over the character view rather than `String`, because round-tripping through a
    /// `String` would take the emphasis, the links and the resolved entity runs with it.
    private static func trimmed(_ text: AttributedString) -> AttributedString {
        let characters = text.characters
        var start = characters.startIndex
        var end = characters.endIndex
        while start < end, characters[start].isWhitespace {
            start = characters.index(after: start)
        }
        while end > start, characters[characters.index(before: end)].isWhitespace {
            end = characters.index(before: end)
        }
        guard start < end else { return AttributedString() }
        return AttributedString(text[start ..< end])
    }

    // MARK: - Describing one image node

    /// What to draw at an image node: the `imeta` entry naming that URL when there is
    /// one, and an entry built from the URL alone when there is not.
    ///
    /// # Why an undescribed node is still media
    ///
    /// A URL no tag describes is one this app cannot know the size of, but the author
    /// still wrote `![…](…)` around it, and a message shows what its author placed.
    /// ``MessageMediaKind`` reads the extension where the tag would have read a MIME
    /// type; when even that says nothing, the node is an image, because the syntax the
    /// author used is the markdown image syntax. That is the reference client's
    /// behaviour exactly — it classifies for the video branch and treats everything
    /// else as a picture — and it is why the failure placeholder matters: an entry with
    /// no declared size draws in a fixed reservation and reports what it was.
    ///
    /// The author's alt text is kept when the tag carries no `alt` of its own. The
    /// reference client drops it and reads a constant to VoiceOver instead; a
    /// description the author wrote is strictly better than one this app invented, and
    /// there is nothing to lose by preferring it.
    private static func describe(_ url: URL, alt: String, by entry: MessageMedia?) -> MessageMedia {
        let alt = authoredAlt(alt)
        guard let entry else {
            let key = url.absoluteString
            return MessageMedia(url: key, kind: MessageMediaKind(url: key) ?? .image, alt: alt)
        }
        guard entry.alt == nil, alt != nil else { return entry }
        return MessageMedia(
            url: entry.url,
            kind: entry.kind,
            mimeType: entry.mimeType,
            pixelSize: entry.pixelSize,
            posterURL: entry.posterURL,
            alt: alt
        )
    }

    /// The alt text an author actually wrote, or `nil`.
    ///
    /// `![](url)` — no alt at all — parses to a lone U+FFFC object replacement, the
    /// placeholder Foundation leaves where an image has no text to stand in for it.
    /// Carrying that through as a description would have VoiceOver announce an
    /// unpronounceable character in place of a picture.
    private static func authoredAlt(_ raw: String) -> String? {
        let alt = raw
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return alt.isEmpty ? nil : alt
    }
}
