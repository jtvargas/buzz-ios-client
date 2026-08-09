import BuzzKit
import Foundation
@testable import Hive
import Testing

/// The name an attachment leaves the app under.
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

    private func file(
        url: String,
        mimeType: String? = nil,
        filename: String? = nil
    ) -> MessageMedia {
        MessageMedia(url: url, kind: .file, mimeType: mimeType, filename: filename)
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

    /// A `data:` URI is a source this app really loads, and its whole payload is its last path
    /// component. Unguarded, the name is thousands of characters and the write fails — which
    /// the reader would be told was a download problem.
    @Test("A data URI does not become a filename the filesystem will refuse")
    func aDataURIIsNotUsedAsAName() {
        let payload = String(repeating: "A", count: 4000)
        let name = MessageMediaExport.filename(
            for: media(url: "data:image/png;base64,\(payload)", mimeType: "image/png"),
            responseMIMEType: nil
        )
        #expect(name == "image.png")
        #expect(name.utf8.count < 255)
    }

    @Test("A URL with no path at all still produces a name")
    func emptyPathStillProducesAName() {
        let name = MessageMediaExport.filename(
            for: media(url: "https://media.example", mimeType: "image/png"),
            responseMIMEType: nil
        )
        #expect(name == "image.png")
    }

    @Test("A file's imeta filename wins over an opaque relay URL and MIME")
    func authoredFileNameWins() {
        let name = MessageMediaExport.filename(
            for: file(
                url: "https://media.example/a3702f85.bin",
                mimeType: "application/octet-stream",
                filename: "addresses.csv"
            ),
            responseMIMEType: "application/octet-stream"
        )
        #expect(name == "addresses.csv")
    }

    @Test("An unsafe path in imeta is reduced to its filename")
    func authoredFileNameIsSafe() {
        let name = MessageMediaExport.filename(
            for: file(url: "https://media.example/a.bin", filename: "../../reports/quarterly.pdf"),
            responseMIMEType: nil
        )
        #expect(name == "quarterly.pdf")
    }

    @Test("A file without an authored name prefers declared type over the URL extension")
    func declaredFileTypeNamesTheFile() {
        let name = MessageMediaExport.filename(
            for: file(url: "https://media.example/abc123.bin", mimeType: "application/pdf"),
            responseMIMEType: "application/octet-stream"
        )
        #expect(name == "abc123.pdf")
    }

    @Test("A non-image response can be written under the imeta filename for Quick Look")
    func fileResponseCanBeFetched() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubFileExportProtocol.self]
        let attachment = file(
            url: "https://file-export.test/report.bin",
            mimeType: "application/pdf",
            filename: "report.pdf"
        )

        let local = try await MessageMediaExport.fetch(
            attachment,
            session: URLSession(configuration: configuration)
        )
        defer { try? FileManager.default.removeItem(at: local.deletingLastPathComponent()) }

        #expect(local.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: local) == StubFileExportProtocol.body)
    }

    @Test("File card sizes use Desktop's binary units and precision")
    func fileCardByteCounts() {
        #expect(FileAttachmentCard.formatByteCount(820) == "820 B")
        #expect(FileAttachmentCard.formatByteCount(1024) == "1.0 KB")
        #expect(FileAttachmentCard.formatByteCount(3_250_586) == "3.1 MB")
        #expect(FileAttachmentCard.formatByteCount(nil) == nil)
    }
}

private final class StubFileExportProtocol: URLProtocol {
    static let body = Data("%PDF-1.7\npreview".utf8)

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "file-export.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let client, let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: 200,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/pdf"]
              )
        else { return }
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: Self.body)
        client.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
