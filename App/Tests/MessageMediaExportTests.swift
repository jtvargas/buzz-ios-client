import BuzzKit
@testable import Hive
import Testing

/// The name a picture leaves the app under.
///
/// # Why this is worth a test at all
///
/// It is one line of the export and it is the line every receiver depends on. Relay media is
/// content-addressed — the path is a digest and carries no extension — so the extension has to
/// be *built*, and the extension is what the share sheet consults to decide which apps may
/// accept the picture at all. A file called `a1b2c3` with no suffix is offered to almost
/// nothing, and the failure is silent: the sheet opens, and the row the reader wanted is
/// simply not in it.
@Suite("Exported media filenames")
struct MessageMediaExportTests {
    private func media(url: String, mimeType: String? = nil) -> MessageMedia {
        MessageMedia(url: url, kind: .image, mimeType: mimeType)
    }

    @Test("A content-addressed URL with no extension takes one from the declared type")
    func declaredTypeNamesTheFile() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example/abc123", mimeType: "image/png"),
            responseMIMEType: nil
        )
        #expect(name == "abc123.png")
    }

    /// The author's tag beats the wire, and this is the case that makes it matter: a host
    /// serving `image/jpeg` for everything would otherwise turn an animation into a still
    /// picture that does not move, under a name promising it would.
    @Test("The declared type wins over the served one")
    func declaredTypeBeatsTheResponse() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example/abc123", mimeType: "image/gif"),
            responseMIMEType: "image/jpeg"
        )
        #expect(name == "abc123.gif")
    }

    @Test("The served type names a file the author's tag said nothing about")
    func servedTypeIsTheFallback() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example/abc123"),
            responseMIMEType: "image/heic"
        )
        #expect(name == "abc123.heic")
    }

    /// The extension already on the URL is trusted last but is still trusted: a picture posted
    /// from somewhere that is not this relay usually has one, and nothing else to go on.
    @Test("A URL's own extension is used when nothing declares a type")
    func carriedExtensionIsTheLastResort() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://example.com/cat.png"),
            responseMIMEType: nil
        )
        #expect(name == "cat.png")
    }

    /// The one that must not be a crash or an empty name: a picture nobody said anything about
    /// is saved as a JPEG, because that is what it will be.
    @Test("A picture with nothing to go on is still given a usable name")
    func unknownTypeStillNamesTheFile() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example/abc123"),
            responseMIMEType: "application/octet-stream"
        )
        #expect(name == "abc123.jpg")
    }

    /// A type that is not an image is refused rather than used. A relay answering `text/html`
    /// is a 404 page, and naming the file `.html` would hide that inside something the share
    /// sheet is happy to pass on.
    @Test("A non-image type is not allowed to name the file")
    func nonImageTypeIsRefused() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example/abc123"),
            responseMIMEType: "text/html"
        )
        #expect(name == "abc123.jpg")
    }

    @Test("A URL with no path at all still produces a name")
    func emptyPathStillProducesAName() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example", mimeType: "image/png"),
            responseMIMEType: nil
        )
        #expect(name == "image.png")
    }
}
