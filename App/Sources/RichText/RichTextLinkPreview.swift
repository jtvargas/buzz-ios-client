import Foundation

/// The link-preview stage: reads the links a message already carries and appends a card
/// for each distinct one to the end of the message.
///
/// # Why it reads links rather than text
///
/// It runs last, over blocks whose inlines are already linked, so it inherits every
/// exclusion the earlier stages fought for instead of restating them:
///
/// - a URL inside `` `code` `` is not a link run, because ``RichTextAutolink`` refuses to
///   scan code spans, so it is not previewed either;
/// - a fenced code block has no runs at all, so a URL in a shell transcript is not
///   previewed;
/// - a picture placed with `![alt](url)` was lifted out of the text by ``RichTextMedia``
///   before autolinking, so an attachment never draws a card beside itself;
/// - a resolved `@`-mention or `#`-channel carries a `hive-entity://` link and an
///   internal message link carries `buzz://`, and ``LinkPreview`` refuses both by scheme.
///
/// Desktop reaches the same set from the other end — it masks code spans, fenced blocks,
/// indented blocks, spoilers and markdown images out of the raw text before it goes
/// looking for URLs (`stripHiddenLinkPreviewContent`). Reading the parse rather than the
/// source is the same rule with nothing left to keep in step.
///
/// # Why the cards go at the end
///
/// A message's own words come first. Desktop appends its cards after the whole document
/// and so does the Flutter composer's picture, and it is the ordering a reader expects:
/// the sentence, then the things it points at. A card drawn where the link *sits* would
/// also split a paragraph in half at whatever point somebody happened to paste a URL.
enum RichTextLinkPreview {
    /// The most cards one message draws.
    ///
    /// Four rather than Desktop's eight because this is a phone: a card is ~62 pt tall,
    /// so four already claim a third of the screen under a message that may be one line
    /// long. Links past the fourth are still links in the text — nothing is hidden, only
    /// un-carded.
    static let maximumCards = 4

    /// `blocks` with a card appended for each distinct previewable link it contains.
    static func append(to blocks: [RichBlock]) -> [RichBlock] {
        let previews = previews(in: blocks)
        guard !previews.isEmpty else { return blocks }
        return blocks + previews.map { .linkPreview($0) }
    }

    /// The cards `blocks` earns, in the order their links first appear, at most
    /// ``maximumCards`` of them and never two for one URL.
    ///
    /// De-duplicated by URL, which is what catches the shape that actually occurs: a
    /// message that names a link in a sentence and again on its own line — an authored
    /// `[label](url)` and a bare `url` — is one card, taking the authored label as its
    /// title.
    ///
    /// Two *spellings* of one link (`github.com/a/b` against `www.github.com/a/b`) are
    /// still two cards. Desktop draws two as well, keyed on the same field, and closing
    /// that would mean deciding here which of `www.`, a trailing slash, a tracking
    /// parameter and a fragment are part of a link's identity — a question with no answer
    /// that is right for every host, in exchange for a duplicate nobody writes.
    static func previews(in blocks: [RichBlock]) -> [LinkPreview] {
        var previews: [LinkPreview] = []
        var seen: Set<URL> = []

        for candidate in links(in: blocks) {
            guard var preview = LinkPreview(url: candidate.url), !seen.contains(preview.url) else { continue }
            seen.insert(preview.url)
            if let title = authoredTitle(candidate, for: preview) {
                preview = LinkPreview(
                    kind: preview.kind,
                    url: preview.url,
                    provider: preview.provider,
                    typeLabel: preview.typeLabel,
                    title: title
                )
            }
            previews.append(preview)
            if previews.count == maximumCards { break }
        }
        return previews
    }

    /// One link found in the message: where it points and the words that were pressed to
    /// reach it.
    private struct Candidate {
        let url: URL
        let text: String
    }

    /// The title an author wrote for the link, or `nil` when the label is the URL itself.
    ///
    /// `[The scroll fix](https://github.com/o/r/pull/61)` says more than `o/r #61` does,
    /// and it says it in the author's words — so an authored label wins over anything
    /// derived here. An autolinked URL's "label" is the URL, which is not a title; so is
    /// a `[https://…](https://…)` somebody pasted twice, which is why this compares
    /// against the target rather than merely checking for emptiness.
    private static func authoredTitle(_ candidate: Candidate, for preview: LinkPreview) -> String? {
        let label = candidate.text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !label.isEmpty, LinkPreview(label)?.url != preview.url else { return nil }
        return label.count <= LinkPreview.maximumTitleLength
            ? label
            : String(label.prefix(LinkPreview.maximumTitleLength)) + "…"
    }

    // MARK: - Walking the message

    /// Every link in the message, in reading order.
    private static func links(in blocks: [RichBlock]) -> [Candidate] {
        blocks.flatMap { block -> [Candidate] in
            switch block {
            case let .paragraph(text), let .quote(text), let .heading(_, text):
                links(in: text)
            case let .bulletList(items), let .orderedList(_, items):
                links(in: items)
            case let .table(table):
                table.cellsInReadingOrder.flatMap { links(in: $0) }
            // A fenced block is raw text that was never inline-parsed, a rule has no
            // words, and an attachment's URL is the picture rather than a link to it.
            case .code, .rule, .media, .linkPreview:
                []
            }
        }
    }

    private static func links(in items: [RichListItem]) -> [Candidate] {
        items.flatMap { links(in: $0.content) + links(in: $0.children) }
    }

    /// The links in one inline, consecutive runs sharing a target joined back together.
    ///
    /// The joining is the point: `[**bold** label](url)` is two runs of one link, because
    /// a run boundary falls wherever *any* attribute changes. Read run by run it would
    /// yield two candidates whose labels are each half of the title the author wrote.
    private static func links(in text: AttributedString) -> [Candidate] {
        var candidates: [Candidate] = []
        for run in text.runs {
            guard let url = run.link else { continue }
            let piece = String(text[run.range].characters)
            if let last = candidates.last, last.url == url {
                candidates[candidates.count - 1] = Candidate(url: url, text: last.text + piece)
            } else {
                candidates.append(Candidate(url: url, text: piece))
            }
        }
        return candidates
    }
}

private extension LinkPreview {
    /// The card a piece of *text* would produce, used only to decide whether a label is
    /// really a label or just the URL again. `nil` for anything that is not a URL, which
    /// is what an ordinary title is.
    init?(_ text: String) {
        guard let url = URL(string: text) else { return nil }
        self.init(url: url)
    }
}
