import Foundation
@testable import Hive
import Testing

/// What a link card says, and which links earn one.
///
/// The parsing half is a parity suite: the rules are Buzz Desktop's
/// (`desktop/src/shared/lib/linkPreview.ts`), and the two clients disagreeing about
/// whether a URL unfurls — or about what the card calls it — is a difference a reader
/// notices immediately when the same message is open on a phone and a laptop.
@Suite("Link previews")
struct LinkPreviewTests {
    private func card(_ string: String) -> LinkPreview? {
        URL(string: string).flatMap { LinkPreview(url: $0) }
    }

    // MARK: - Known providers

    @Test("a pull request is titled by repository and number")
    func pullRequest() throws {
        let preview = try #require(card("https://github.com/jtvargas/buzz-ios-client/pull/61"))

        #expect(preview.kind == .githubPullRequest)
        #expect(preview.title == "jtvargas/buzz-ios-client #61")
        #expect(preview.provider == "GitHub")
        #expect(preview.typeLabel == "PR")
        #expect(preview.caption == "GitHub · PR")
    }

    @Test("an issue is a distinct kind from a pull request")
    func issue() throws {
        let preview = try #require(card("https://github.com/o/r/issues/7"))

        #expect(preview.kind == .githubIssue)
        #expect(preview.title == "o/r #7")
        #expect(preview.caption == "GitHub · issue")
    }

    @Test("a bare repository is titled owner/repo")
    func repository() throws {
        let preview = try #require(card("https://github.com/o/r"))

        #expect(preview.kind == .githubRepository)
        #expect(preview.title == "o/r")
    }

    /// Desktop's rule, and the reason for it: `owner/repo` under a link to one line of
    /// one file describes the repository the link is *part of*, not the link.
    @Test("a link deeper than a repository falls through to an ordinary web card")
    func deepGithubLink() throws {
        let preview = try #require(card("https://github.com/o/r/blob/main/README.md"))

        #expect(preview.kind == .web)
        #expect(preview.provider == nil)
        #expect(preview.title == "/o/r/blob/main/README.md")
        #expect(preview.caption == "github.com")
    }

    @Test("a pull request path with a non-numeric number is not a pull request")
    func nonNumericPullRequest() throws {
        #expect(card("https://github.com/o/r/pull/latest")?.kind == .web)
        #expect(card("https://github.com/o/r/tree/main")?.kind == .web)
    }

    /// The form GitHub's own UI hands out most often. It is a tab of the pull request,
    /// not a different page.
    @Test("a pull request's files tab is still that pull request")
    func pullRequestTab() throws {
        let preview = try #require(card("https://github.com/o/r/pull/61/files"))

        #expect(preview.kind == .githubPullRequest)
        #expect(preview.title == "o/r #61")
    }

    @Test("a Linear issue is titled by its identifier")
    func linearIssue() throws {
        let preview = try #require(card("https://linear.app/acme/issue/eng-1421/fix-the-scroll"))

        #expect(preview.kind == .linearIssue)
        #expect(preview.title == "ENG-1421")
        #expect(preview.caption == "Linear · issue")
    }

    @Test("a Linear path with no issue identifier is an ordinary web card")
    func linearWithoutIssue() throws {
        #expect(card("https://linear.app/acme/team/ENG")?.kind == .web)
        #expect(card("https://linear.app/issue/ENG-1")?.kind == .web)
    }

    @Test(
        "Google file links are named for what they are",
        arguments: [
            ("https://docs.google.com/document/d/abc/edit", LinkPreview.Kind.googleDocument, "Document"),
            ("https://docs.google.com/spreadsheets/d/abc/edit", .googleSpreadsheet, "Spreadsheet"),
            ("https://docs.google.com/presentation/d/abc/edit", .googlePresentation, "Presentation"),
            ("https://drive.google.com/file/d/abc/view", .googleDriveFile, "Drive file"),
            ("https://drive.google.com/drive/folders/abc", .googleDriveFolder, "Drive folder"),
            ("https://drive.google.com/open?id=abc", .googleDriveFile, "Drive file"),
        ]
    )
    func googleLinks(link: String, kind: LinkPreview.Kind, title: String) throws {
        let preview = try #require(card(link))

        #expect(preview.kind == kind)
        #expect(preview.title == title)
    }

    @Test("a host that merely looks like a provider is not one")
    func lookalikeHost() throws {
        #expect(card("https://notgithub.com/o/r/pull/1")?.kind == .web)
        #expect(card("https://github.com.evil.example/o/r/pull/1")?.kind == .web)
    }

    @Test("www is stripped for reading but the provider still resolves")
    func wwwPrefix() throws {
        let preview = try #require(card("https://www.github.com/o/r/pull/1"))

        #expect(preview.kind == .githubPullRequest)
        #expect(preview.host == "github.com")
    }

    // MARK: - Ordinary web links

    @Test("an ordinary link is titled by its path and captioned by its host")
    func webLink() throws {
        let preview = try #require(card("https://developer.apple.com/documentation/swiftui/scrollposition"))

        #expect(preview.title == "/documentation/swiftui/scrollposition")
        #expect(preview.caption == "developer.apple.com")
        #expect(preview.host == "developer.apple.com")
    }

    /// With nothing but a host to show, the title *is* the host — so a caption saying it
    /// again would print the same word twice on a two-line card.
    @Test("a bare domain is titled by its host and carries no caption")
    func bareDomain() throws {
        let preview = try #require(card("https://example.com"))

        #expect(preview.title == "example.com")
        #expect(preview.caption == nil)
    }

    @Test("a query and a fragment are left off the title")
    func queryAndFragment() throws {
        #expect(card("https://example.com/search?q=swift#results")?.title == "/search")
    }

    @Test("a percent-encoded path is shown decoded")
    func encodedPath() throws {
        #expect(card("https://example.com/notes/my%20file")?.title == "/notes/my file")
    }

    @Test("a title longer than the limit is truncated rather than carried whole")
    func longTitle() throws {
        let preview = try #require(card("https://example.com/\(String(repeating: "a", count: 400))"))

        #expect(preview.title.count == LinkPreview.maximumTitleLength + 1) // + the ellipsis
        #expect(preview.title.hasSuffix("…"))
    }

    // MARK: - What earns no card at all

    @Test(
        "a link this app routes itself, or one that is not a web link, gets no card",
        arguments: [
            "buzz://message?channel=abc&id=def",
            "hive-entity://user/9719efcf",
            "mailto:someone@example.com",
            "ftp://example.com/file",
        ]
    )
    func refusedSchemes(link: String) throws {
        #expect(card(link) == nil)
    }

    /// The author linked a picture without embedding it. The link stays a link; a card
    /// under it reading `photo.png` would be the same three words a second time.
    @Test("a link that names a picture or a video gets no card")
    func mediaLinks() throws {
        #expect(card("https://example.com/photo.png") == nil)
        #expect(card("https://example.com/clip.mp4") == nil)
        #expect(card("https://example.com/photo.png?v=2") == nil)
    }
}
