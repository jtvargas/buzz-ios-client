import CryptoKit
import Foundation

/// The document written back out as a real file, so the share sheet has one to hand over.
///
/// # Why a file and not the URL
///
/// Sharing the link shares an *address*: whoever receives it needs the network, and on a
/// hosted relay they need the credentials too. Sharing the file shares the thing itself —
/// AirDrop, Save to Files, and a mail attachment all take it, and it arrives named as its
/// author named it rather than as a URL somebody has to open. The source text is what gets
/// written, not the rendered blocks: a `.md` that pasted as prose would have lost the very
/// markup this feature exists to show.
enum MarkdownDocumentFile {
    /// Where a document's copy lives. One directory per document, keyed by the URL, so
    /// opening the same file twice overwrites rather than accumulating — a share sheet
    /// opened repeatedly must not fill the temporary directory with copies.
    ///
    /// The key is a hash rather than the URL's own path: two files can share a name, and a
    /// URL contains characters a path component cannot. A digest rather than `hashValue`,
    /// which is seeded per process — the same document would land in a new directory on
    /// every launch, and the copies would pile up instead of being overwritten.
    static func directory(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return FileManager.default.temporaryDirectory
            .appending(path: "MarkdownDocuments", directoryHint: .isDirectory)
            .appending(path: digest, directoryHint: .isDirectory)
    }

    /// Writes `source` out under the document's own name and returns it, or `nil` if the
    /// write failed.
    ///
    /// Failure is not an error worth showing: the share button falls back to the document's
    /// URL, which is what the reader pressed to get here, so the sheet still shares
    /// something rather than presenting a problem nobody can act on.
    static func write(_ source: String, for document: MarkdownDocument) -> URL? {
        let directory = directory(for: document.url)
        let file = directory.appending(path: document.name, directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try source.write(to: file, atomically: true, encoding: .utf8)
            return file
        } catch {
            return nil
        }
    }
}
