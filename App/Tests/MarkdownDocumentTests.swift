import Foundation
@testable import Hive
import Testing

/// Which links are markdown files, where pressing one goes, and what the reader is handed
/// when it opens.
///
/// The classification is the load-bearing half: it decides both what the card says and
/// whether a press leaves the app, so a URL misread in either direction is a link that
/// behaves differently from the one beside it.
@Suite("Markdown documents")
struct MarkdownDocumentTests {
    private func document(_ string: String) -> MarkdownDocument? {
        URL(string: string).flatMap { MarkdownDocument(url: $0) }
    }

    private func route(_ string: String) -> RichTextRoute? {
        URL(string: string).flatMap { RichTextRoute(url: $0) }
    }

    // MARK: - What is a document

    @Test("every markdown extension is one, and the name is the file's own")
    func recognisedExtensions() throws {
        let raw = try #require(document("https://raw.githubusercontent.com/mxstbr/markdown-test-file/master/TEST.md"))
        #expect(raw.name == "TEST.md")

        #expect(document("https://example.invalid/notes.markdown")?.name == "notes.markdown")
        #expect(document("https://example.invalid/a/b/CHANGELOG.MD")?.name == "CHANGELOG.MD")
        // Percent-encoding is decoded by `lastPathComponent`, so the title reads as authored.
        #expect(document("https://example.invalid/release%20notes.md")?.name == "release notes.md")
    }

    @Test("a query string does not hide the extension, and a fragment does not invent one")
    func extensionIsReadFromThePath() {
        #expect(document("https://example.invalid/README.md?token=abc") != nil)
        #expect(document("https://example.invalid/page#section.md") == nil)
    }

    @Test("anything that is not a fetchable markdown file is not a document")
    func rejections() {
        #expect(document("https://example.invalid/cat.png") == nil)
        #expect(document("https://example.invalid/index.html") == nil)
        // `.mdx` is markdown with a component language in it; rendered as plain markdown it
        // prints its own imports as prose.
        #expect(document("https://example.invalid/page.mdx") == nil)
        #expect(document("https://example.invalid/notes") == nil)
        // A scheme this cannot fetch, and the app's own entity scheme.
        #expect(document("file:///Users/someone/notes.md") == nil)
        #expect(document("hive-entity://user/abc.md") == nil)
    }

    // MARK: - Where a press goes

    @Test("a markdown link opens the reader and every other web link still leaves the app")
    func routing() throws {
        let pressed = route("https://example.invalid/docs/PLAN.md")
        guard case let .markdownDocument(document) = pressed else {
            Issue.record("expected a markdown route, got \(String(describing: pressed))")
            return
        }
        #expect(document.name == "PLAN.md")

        guard case .external = try #require(route("https://example.invalid/docs/plan.html")) else {
            Issue.record("an ordinary web link must still hand back to the system")
            return
        }
    }

    @Test("an entity link is never re-read as a file")
    func entitiesWinOverTheExtension() throws {
        // The document check runs inside the `.web` arm, after the internal schemes have
        // already claimed what is theirs — so a mention or a channel cannot be turned into a
        // file by whatever its identifier happens to end with.
        guard case .profile = try #require(route("hive-entity://user/abc.md")) else {
            Issue.record("a mention must resolve as a profile")
            return
        }
    }

    // MARK: - The card

    @Test("a markdown file is carded as a document, titled by its filename")
    func card() throws {
        let url = try #require(URL(string: "https://raw.githubusercontent.com/mxstbr/markdown-test-file/master/TEST.md"))
        let preview = try #require(LinkPreview(url: url))

        #expect(preview.kind == .markdownDocument)
        #expect(preview.title == "TEST.md")
        #expect(preview.caption == "Markdown · document")
    }

    @Test("a repository link is still GitHub's card, not a document")
    func knownProvidersWin() throws {
        // Two segments is a repository, whatever it is called. Only a link that names a file
        // becomes a document.
        let repo = try #require(URL(string: "https://github.com/jtvargas/buzz-ios-client"))
        #expect(LinkPreview(url: repo)?.provider == "GitHub")
    }

    @Test("a GitHub file link is fetched from the raw host, and still opens in the browser as linked")
    func githubBlobLinksAreRewrittenForFetching() throws {
        // The way people actually share a markdown file. The viewer URL serves GitHub's *page*,
        // so fetching it verbatim gets HTML and the reader would fail on the commonest link
        // this feature exists for.
        let blob = try #require(document("https://github.com/jtvargas/buzz-ios-client/blob/main/docs/README.md"))

        #expect(blob.name == "README.md")
        #expect(
            blob.fetchURL.absoluteString
                == "https://raw.githubusercontent.com/jtvargas/buzz-ios-client/main/docs/README.md"
        )
        // Open in browser hands over what was linked, not the plain text behind it.
        #expect(blob.url.host() == "github.com")
    }

    @Test("a raw link is fetched exactly as written")
    func nonGitHubURLsAreNotRewritten() throws {
        let raw = try #require(document("https://raw.githubusercontent.com/mxstbr/markdown-test-file/master/TEST.md"))
        #expect(raw.fetchURL == raw.url)

        // Another forge's viewer URL is left alone rather than guessed at.
        let other = try #require(document("https://gitlab.example/group/project/-/blob/main/README.md"))
        #expect(other.fetchURL == other.url)
    }

    // MARK: - What the sheet renders

    @Test("a document is the message pipeline without the two message-only stages")
    func documentRendering() {
        let message = MarkdownDocumentContent.message(for: """
        # Title

        Some **bold** text and a [link](https://example.invalid).

        - one
        - two

        > quoted

        ```swift
        let x = 1
        ```
        """)

        let kinds = message.blocks.compactMap { block -> String? in
            switch block {
            case .heading: "heading"
            case .paragraph: "paragraph"
            case .bulletList: "list"
            case .quote: "quote"
            case .code: "code"
            case .rule: "rule"
            case .sourceBlankLine: nil
            default: "other"
            }
        }
        #expect(kinds == ["heading", "paragraph", "list", "quote", "code"])
    }

    @Test("an anchor link is a link, not a channel")
    func anchorsAreNotChannels() {
        // Every long README opens with a table of contents of `[Overview](#overview)`. The
        // entity pass would resolve `#overview` against the workspace's channel map and draw a
        // pill that navigates somewhere the document's author never pointed at — which is why
        // a document skips that stage. Asserted as "no block became a channel pill": the
        // paragraph keeps the link it was authored with.
        let message = MarkdownDocumentContent.message(for: "* [Overview](#overview)")
        guard case let .bulletList(items) = message.blocks.first else {
            Issue.record("expected the table-of-contents line to stay a list")
            return
        }
        let text = String(RichTextProbe.inline(of: items[0]).characters)
        #expect(text == "Overview")
    }

    @Test("the AST owns lazy list continuations without rewriting the document source")
    func lazyListContinuation() {
        let message = MarkdownDocumentContent.message(for: "- first line\ncontinued line")
        guard case let .bulletList(items) = message.blocks.first else {
            Issue.record("expected a list")
            return
        }
        #expect(String(RichTextProbe.inline(of: items[0]).characters) == "first line\ncontinued line")
    }

    @Test("a blockquote after a list remains its own block")
    func quoteAfterListIsNotAContinuation() {
        let message = MarkdownDocumentContent.message(for: "- item\n> quote")
        #expect(message.blocks.count == 2)
        if case .bulletList = message.blocks[0] {} else { Issue.record("expected list first") }
        if case .quote = message.blocks[1] {} else { Issue.record("expected quote second") }
    }

    @Test("document HTML preserves nested quote and list-item blocks")
    func nestedBlocksRenderAsHTML() {
        let message = MarkdownDocumentContent.message(for: """
        > before
        >
        > ```swift
        > let x = 1
        > ```

        - item

          ```bash
          echo ok
          ```
        """)
        let html = MarkdownDocumentHTML.body(for: message)
        #expect(html.contains("<blockquote>"))
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("<li>"))
        #expect(html.contains("<pre><code class=\"language-bash\">"))
    }

    @Test("a file too long to draw is cut at a line break and says so")
    func truncation() {
        let line = String(repeating: "x", count: 100) + "\n"
        let long = String(repeating: line, count: MarkdownDocumentContent.characterLimit / 100 + 40)
        let message = MarkdownDocumentContent.message(for: long)

        // The rule and the explanation are the last two blocks, so a reader who scrolls to the
        // bottom learns the document did not end there.
        #expect(message.blocks.count >= 2)
        #expect(message.blocks[message.blocks.count - 2] == .rule)
        guard case let .paragraph(note) = message.blocks[message.blocks.count - 1] else {
            Issue.record("expected a closing note")
            return
        }
        #expect(String(note.characters).contains("too long"))
    }

    @Test("a table renders as cells, not as a GRDB SQL literal")
    func tableRendersAsCells() {
        // The regression this exists for: `tableHTML` joined its rows with the closure's
        // return type left to inference, and GRDB — reachable from this target — offers both
        // `ExpressibleByStringInterpolation` on `SQL` and `joined(separator:) -> SQL` on a
        // collection of them. Both readings type-checked, the solver chose `SQL`, and the
        // value interpolated into the surrounding literal as its own `description`. Every
        // table in every opened document rendered as
        // `SQL(elements: [GRDB.SQL.Element.sql("", []), …])`.
        //
        // Asserted on the rendered HTML rather than on the parsed blocks, because the parse
        // was never wrong — only the serialisation was.
        let message = MarkdownDocumentContent.message(for: """
        | Phase | State |
        |-------|-------|
        | One   | done  |
        | Two   | in progress |
        """)
        let html = MarkdownDocumentHTML.body(for: message)

        #expect(html.contains("<table>"))
        #expect(html.contains("<th"))
        #expect(html.contains("<td"))
        #expect(html.contains("Phase"))
        #expect(html.contains("in progress"))
        // The exact shape of the leak, so a future inference change cannot bring it back
        // quietly under a different element name.
        #expect(!html.contains("SQL("))
        #expect(!html.contains("GRDB"))
    }
}
