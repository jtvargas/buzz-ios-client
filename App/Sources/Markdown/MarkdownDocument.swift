import Foundation

/// A link that points at a markdown file, and the name to put on it.
///
/// # Why a markdown file is not media
///
/// ``MessageMediaKind`` classifies pictures and video — the things a message *draws* — and a
/// `.md` URL is deliberately not one of them: it stays a link in the text, exactly as it does
/// today, and this type is what lets a link know it points at a document worth opening in the
/// app rather than handing to Safari. Nothing about the message pipeline changes.
struct MarkdownDocument: Identifiable, Hashable, Sendable {
    /// The document's own URL, and its identity — the same file linked twice is one document.
    let url: URL
    /// The file's name as authored, which is what the card and the sheet's title show.
    let name: String

    var id: URL { url }

    /// The extensions this recognises.
    ///
    /// Extension and not MIME type, because the classification happens over a URL sitting in a
    /// message's text with nothing fetched — the same rule ``LinkPreview`` follows and for the
    /// same reason: asking the host what a link is would fetch every link every reader scrolls
    /// past. `.mdx` is deliberately absent: it is markdown with a component language embedded
    /// in it, and rendering one as plain markdown prints its imports as prose.
    static let fileExtensions: Set<String> = ["md", "markdown", "mdown", "mkd"]

    /// The document `url` names, or `nil` when it does not name one.
    ///
    /// `http(s)` only, matching ``LinkPreview``: a `file://` or `hive-entity://` URL that
    /// happens to end in `.md` is not something to fetch.
    init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              Self.fileExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        // `lastPathComponent` is already percent-decoded, so a file posted as `release%20notes.md`
        // reads as its author wrote it. A URL whose path is empty has none to show.
        let component = url.lastPathComponent
        guard !component.isEmpty, component != "/" else { return nil }
        self.url = url
        name = component
    }

    /// The URL the reader actually fetches, which is not always the one that was linked.
    ///
    /// `github.com/owner/repo/blob/main/README.md` is the way people share a markdown file and
    /// it does not serve one — it serves the page GitHub draws around it, so fetching it gets
    /// HTML and the reader would open on "couldn't download this file" for the single most
    /// common link this feature exists to handle. GitHub serves the bytes from
    /// `raw.githubusercontent.com` at the same owner/ref/path, and the rewrite is exact rather
    /// than a guess: every segment comes from the original, and only the `blob` marker is
    /// dropped.
    ///
    /// Only this one host. Another forge's viewer URL is left alone and simply fails to a sheet
    /// offering the browser, which is honest — inventing a raw host per forge is a list that
    /// goes stale silently.
    ///
    /// ``url`` stays the linked one, because that is what Open in browser must hand over: a
    /// reader who wants the page wants the page, not the plain text behind it.
    var fetchURL: URL {
        guard url.host()?.lowercased() == "github.com" else { return url }
        let segments = url.pathComponents.filter { $0 != "/" }
        guard segments.count >= 5, segments[2] == "blob" else { return url }
        var raw = URLComponents()
        raw.scheme = url.scheme
        raw.host = "raw.githubusercontent.com"
        // The owner, the repo, then everything after `blob` — which is the ref followed by the
        // path, in the order raw.githubusercontent.com expects them.
        raw.path = "/" + (segments[0 ... 1] + segments[3...]).joined(separator: "/")
        return raw.url ?? url
    }
}
