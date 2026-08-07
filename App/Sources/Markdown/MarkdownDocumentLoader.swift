import BuzzKit
import Foundation

/// Fetches a markdown file and decodes it to text.
///
/// Separate from the sheet so the failure cases are decided in one place and can be read
/// without a view: what a reader is told when a file will not load is a product decision, and
/// it should not be spelled out inside a `catch` in a `body`.
enum MarkdownDocumentLoader {
    /// Why a document did not open, in the words the reader is shown.
    ///
    /// None of them name a status code, for the reason ``MessageMediaExport/Failure`` gives:
    /// somebody who tapped a file can act on "it isn't there" and can do nothing with a 502.
    enum Failure: LocalizedError, Equatable {
        /// The bytes never arrived, or the host answered with something that is not the file.
        case download
        /// The bytes arrived and are not text this can read.
        case decode
        /// The file is larger than this will pull down.
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .download: "Hive couldn't download this file. Check your connection and try again."
            case .decode: "This file isn't readable as text."
            case .tooLarge: "This file is too large to open in Hive."
            }
        }
    }

    /// The most this will download.
    ///
    /// Guards the transfer rather than the render — ``MarkdownDocumentContent/characterLimit``
    /// does that — because the two failures are different: a 5 MB file is a wait on a phone
    /// network, and refusing it before the wait is the honest answer. Well past any document
    /// somebody links in a conversation.
    static let byteLimit = 4 * 1024 * 1024

    /// The session every document fetch runs over.
    ///
    /// One for the process, and the loader's own idle timeout, for the reasons
    /// ``MessageMediaExport/session`` records: a host that is not there should fail in fifteen
    /// seconds rather than sixty, and a `URLSession` per sheet accumulates for the life of the
    /// app. Ephemeral because a document is read once and re-read from the host, not from a
    /// cache that would hand back yesterday's revision of a file somebody is actively editing.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// Downloads `document` and returns its text.
    ///
    /// `authorization` is the same signer the pictures use. A hosted relay can require a signed
    /// read on its blob store — a file uploaded into a community is served from exactly that
    /// host — while a raw file on the open web needs none, so the header is attached when there
    /// is one to attach and the request is otherwise plain. See ``MediaReadAuthorizing``.
    static func text(
        for document: MarkdownDocument,
        session: URLSession = MarkdownDocumentLoader.session,
        authorization: (any MediaReadAuthorizing)? = nil
    ) async throws -> String {
        // The fetchable form, which for a GitHub viewer URL is not the linked one —
        // see ``MarkdownDocument/fetchURL``.
        let source = document.fetchURL
        var request = URLRequest(url: source)
        if let header = await authorization?.authorization(for: source) {
            request.setValue(header, forHTTPHeaderField: "Authorization")
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.download
        }
        // A host that is reachable and has lost the object answers with a *page*, not with a
        // transport error, so an unchecked body is how an HTML 404 gets rendered as the
        // document. The same both-halves check the picture fetch makes.
        if let http = response as? HTTPURLResponse {
            guard (200 ..< 300).contains(http.statusCode) else { throw Failure.download }
            if let mime = http.mimeType?.lowercased(), mime == "text/html" { throw Failure.download }
        }
        guard data.count <= byteLimit else { throw Failure.tooLarge }
        // UTF-8 first because that is what a markdown file is in practice; Latin-1 as the
        // fallback because it cannot fail, which turns "a file written in some 8-bit encoding"
        // into a few wrong glyphs rather than an error page.
        guard let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else { throw Failure.decode }
        return text
    }
}
