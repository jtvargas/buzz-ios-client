import BuzzKit
import Foundation

/// What a link preview card says about a URL — derived from the URL itself, without
/// fetching the page behind it.
///
/// # Why nothing here is fetched
///
/// Every field below is a pure function of the link's own text. That is a deliberate
/// choice and it is worth being explicit about, because the obvious alternative — asking
/// the site for its `<title>` and its Open Graph tags, the way a server-side unfurler
/// does — is not the same thing on a phone as it is on a server:
///
/// - It would fetch **every link anybody posts**, from **every reader's device**, at the
///   moment the message scrolls into view. Whoever owns that host learns the IP address
///   of every member of the channel, and learns it again on every re-read. A server
///   unfurls once, for everybody, from one address; a client unfurls once per reader.
/// - Buzz Desktop, which has a whole Rust process to do it in, still declines: its
///   `fetch_link_preview_title` command refuses any URL that is not a Google Docs or
///   Drive file, and every other card it draws is parsed from the URL exactly as this is
///   (`desktop/src/shared/lib/linkPreview.ts`). Matching that rule is also what makes the
///   two clients agree about which links unfurl and what the card says.
///
/// The one thing that *is* fetched is the site's favicon — see ``LinkPreviewIcon`` — and
/// only because it is a fixed-size image in a fixed-size slot, so it can arrive late
/// without moving anything.
///
/// # The shape of a card
///
/// A caption line and a title, and which of the two carries the domain depends on how
/// much is known:
///
/// - A **known provider** — a GitHub pull request, a Linear issue, a Google doc — has a
///   real name to show, so the title is that name (`jtvargas/buzz-ios-client #61`) and
///   the caption says where it lives (`GitHub · PR`).
/// - **Any other URL** has no name that is not invented, so the title is the URL's own
///   path and the caption is its host. The path is shown as written rather than
///   de-slugged into sentence case: `/documentation/swiftui/scrollposition` is what the
///   author linked to, and "Documentation Swiftui Scrollposition" is a guess dressed up
///   as a fact.
struct LinkPreview: Equatable, Hashable, Sendable {
    /// The resource a card describes. Drives the fallback glyph and nothing else —
    /// the words on the card are in ``provider``, ``typeLabel`` and ``title``.
    enum Kind: Equatable, Hashable, Sendable {
        case githubPullRequest
        case githubIssue
        case githubRepository
        case linearIssue
        case googleDriveFile
        case googleDriveFolder
        case googleDocument
        case googleSpreadsheet
        case googlePresentation
        /// A URL from a host with no rules of its own.
        case web
    }

    let kind: Kind
    /// The link as it will be opened. Not necessarily the characters the author typed:
    /// a bare `github.com/a/b` is normalised to `https://` so the card and the tap agree.
    let url: URL
    /// The service the link belongs to (`GitHub`), or `nil` for an ordinary web link,
    /// whose caption is its host instead.
    let provider: String?
    /// What kind of thing it is (`PR`, `issue`, `document`), or `nil` when the host says
    /// nothing about that.
    let typeLabel: String?
    /// The card's headline.
    let title: String

    /// The host, without a leading `www.` — the caption of an ordinary web card, and the
    /// domain a favicon is asked of.
    var host: String {
        Self.normalizedHost(url) ?? ""
    }

    /// The caption above the title: `GitHub · PR` where the provider is known, the bare
    /// host otherwise. `nil` when the title is already the host and a caption would
    /// print it twice.
    var caption: String? {
        if let provider {
            return typeLabel.map { "\(provider) · \($0)" } ?? provider
        }
        let host = host
        return host.isEmpty || host == title ? nil : host
    }
}

// MARK: - Parsing

extension LinkPreview {
    /// The card for `url`, or `nil` when it is not a link this app draws one for.
    ///
    /// Refused: anything that is not `http`/`https` (which is every internal
    /// `buzz://message`, every resolved `hive-entity://` mention, and every `mailto:`),
    /// a URL with no host, and a URL that names a picture or a video — an author who
    /// linked to `photo.png` without embedding it gets a link, and a card saying
    /// "photo.png" beneath it would be the same three words twice.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              Self.normalizedHost(url) != nil,
              MessageMediaKind(url: url.absoluteString) == nil
        else { return nil }

        if let known = Self.github(url) ?? Self.linear(url) ?? Self.googleDrive(url) ?? Self.googleDocs(url) {
            self = known
            return
        }
        self.init(kind: .web, url: url, provider: nil, typeLabel: nil, title: Self.webTitle(url))
    }

    /// The host in the form the card shows and the favicon is asked of, or `nil` when
    /// there is not one.
    static func normalizedHost(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let trimmed = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The path segments with the root separator dropped.
    ///
    /// `pathComponents` hands these back already percent-decoded, which is what a card
    /// shows and what a path is matched against — a second `removingPercentEncoding` here
    /// would decode `my%2520file` twice and print a filename its author never wrote.
    private static func segments(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" }
    }

    // MARK: Known hosts

    /// `github.com/owner/repo`, `…/pull/12`, `…/issues/12`.
    ///
    /// Anything deeper — a file at a commit, a diff, a release — falls through to the
    /// ordinary web card rather than being announced as a repository it is only *part*
    /// of. That is Desktop's rule and it is the right one: `owner/repo` under a card for
    /// a link to one line of one file says less than the path does.
    private static func github(_ url: URL) -> LinkPreview? {
        guard normalizedHost(url) == "github.com" else { return nil }
        let segments = segments(url)
        guard let owner = segments.first, let repo = segments.dropFirst().first else { return nil }
        let repoLabel = "\(owner)/\(repo)"

        guard segments.count > 2 else {
            return LinkPreview(
                kind: .githubRepository, url: url, provider: "GitHub", typeLabel: "repo", title: repoLabel
            )
        }
        // Deeper than the number is still the same pull request: `/pull/61/files` and
        // `/pull/61/commits/…` are tabs of one page, and GitHub's own UI hands out the
        // `/files` form constantly. Desktop reads the first four segments and ignores the
        // rest for exactly that reason.
        guard segments.count >= 4, !segments[3].isEmpty, segments[3].allSatisfy(\.isNumber) else { return nil }
        let number = segments[3]
        switch segments[2] {
        case "pull":
            return LinkPreview(
                kind: .githubPullRequest, url: url, provider: "GitHub", typeLabel: "PR",
                title: "\(repoLabel) #\(number)"
            )
        case "issues":
            return LinkPreview(
                kind: .githubIssue, url: url, provider: "GitHub", typeLabel: "issue",
                title: "\(repoLabel) #\(number)"
            )
        default:
            return nil
        }
    }

    /// `linear.app/<workspace>/issue/ABC-123`.
    private static func linear(_ url: URL) -> LinkPreview? {
        guard normalizedHost(url) == "linear.app" else { return nil }
        let segments = segments(url)
        guard let issueIndex = segments.firstIndex(where: { $0.lowercased() == "issue" }), issueIndex >= 1,
              issueIndex + 1 < segments.count
        else { return nil }
        let identifier = segments[issueIndex + 1].uppercased()
        guard isLinearIdentifier(identifier) else { return nil }
        return LinkPreview(kind: .linearIssue, url: url, provider: "Linear", typeLabel: "issue", title: identifier)
    }

    /// Whether `value` is a Linear issue identifier — a team key, a hyphen, a number,
    /// as in `ENG-1421`.
    ///
    /// Spelled out rather than written as a regular expression because this file is the
    /// only place in the app that would have needed one, and the rule is three lines of
    /// reading either way.
    private static func isLinearIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let key = parts[0], number = parts[1]
        guard let first = key.first, first.isLetter,
              key.allSatisfy({ $0.isLetter || $0.isNumber })
        else { return false }
        return !number.isEmpty && number.allSatisfy(\.isNumber)
    }

    /// `drive.google.com/file/d/…`, `/drive/folders/…`, `/open?id=…`.
    ///
    /// The titles are the words for what the thing is, because that is genuinely all the
    /// URL knows: a Drive id is opaque. Desktop asks the page for its real title and can,
    /// because it fetches from a desktop that is signed in; a phone asking the same
    /// question unauthenticated is handed a sign-in page, so this does not ask.
    private static func googleDrive(_ url: URL) -> LinkPreview? {
        guard normalizedHost(url) == "drive.google.com" else { return nil }
        let segments = segments(url)
        if let folderIndex = segments.firstIndex(of: "folders"), folderIndex + 1 < segments.count {
            return LinkPreview(
                kind: .googleDriveFolder, url: url, provider: "Google Drive", typeLabel: "folder",
                title: "Drive folder"
            )
        }
        let isFile = segments.count >= 3 && segments[0] == "file" && segments[1] == "d"
        let isOpenByID = segments.first == "open"
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "id" } == true
        guard isFile || isOpenByID else { return nil }
        return LinkPreview(
            kind: .googleDriveFile, url: url, provider: "Google Drive", typeLabel: "file", title: "Drive file"
        )
    }

    /// `docs.google.com/{document,spreadsheets,presentation}/d/…`.
    private static func googleDocs(_ url: URL) -> LinkPreview? {
        guard normalizedHost(url) == "docs.google.com" else { return nil }
        let segments = segments(url)
        guard segments.count >= 3, segments[1] == "d" else { return nil }
        switch segments[0] {
        case "document":
            return LinkPreview(
                kind: .googleDocument, url: url, provider: "Google Docs", typeLabel: "document", title: "Document"
            )
        case "spreadsheets":
            return LinkPreview(
                kind: .googleSpreadsheet, url: url, provider: "Google Sheets", typeLabel: "spreadsheet",
                title: "Spreadsheet"
            )
        case "presentation":
            return LinkPreview(
                kind: .googlePresentation, url: url, provider: "Google Slides", typeLabel: "presentation",
                title: "Presentation"
            )
        default:
            return nil
        }
    }

    // MARK: Ordinary web links

    /// The headline for a host with no rules: its path, decoded, with the query and
    /// fragment left off, or the host itself when the link is to a bare domain.
    ///
    /// Truncated at a length no phone can show in one line anyway. `Text` would truncate
    /// it too, but a 2 KB path also has to be hashed by the render memo's key and read
    /// out by VoiceOver, and neither is work worth doing for characters nobody sees.
    private static func webTitle(_ url: URL) -> String {
        let path = segments(url).joined(separator: "/")
        guard !path.isEmpty else { return normalizedHost(url) ?? url.absoluteString }
        let title = "/\(path)"
        return title.count <= maximumTitleLength ? title : String(title.prefix(maximumTitleLength)) + "…"
    }

    /// The longest title a card carries.
    static let maximumTitleLength = 120
}
