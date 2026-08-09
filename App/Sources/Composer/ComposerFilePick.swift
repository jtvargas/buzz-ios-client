import Foundation
import UniformTypeIdentifiers

/// A file chosen from the document picker, as the composer's pipeline needs it.
///
/// The sibling of a photo pick: same ``ComposerPickedItem`` seam, so the model's
/// bounding, its concurrency ceiling and its removal-during-preparation rules apply
/// to a file without any of them learning that files exist. `ComposerAttachment`'s
/// own doc already anticipated this — "a camera capture and a file import are
/// conformances, not a second pipeline."
///
/// # The URL is borrowed, not owned
///
/// `fileImporter` hands back a **security-scoped** URL: a location this process may
/// read only between `startAccessingSecurityScopedResource()` and its stop, and only
/// until the picker's grant lapses. So the bytes are read once, here, and everything
/// afterwards works from `Data`. Holding the URL to read later is the bug this shape
/// exists to avoid — it works while the picker is on screen and fails afterwards,
/// which is the worst way for it to fail.
struct ComposerFilePick: ComposerPickedItem {
    let url: URL

    /// What the file is called, carried onto the message as the link's label.
    ///
    /// The last path component rather than anything cleverer: it is what the author
    /// saw in the picker, and the relay stores it verbatim. The mobile client
    /// sanitises control characters and caps at 255 bytes on the way out
    /// (`media_upload.dart:527`); that belongs on the upload side, where both
    /// clients' filenames land in the same `imeta` tag.
    var suggestedFilename: String? { url.lastPathComponent }

    /// This is a document, so bytes that are not a picture are still an attachment.
    var isDocument: Bool { true }

    func loadData() async throws -> Data {
        let url = url
        return try await Task.detached(priority: .userInitiated) {
            // A file in the app's own container is not security-scoped and returns
            // false here; that is not a failure, and reading it is still allowed.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            guard !data.isEmpty else { throw ComposerAttachmentError.emptyPick }
            return data
        }.value
    }
}

extension ComposerFilePick {
    /// The type to declare for these bytes.
    ///
    /// `application/octet-stream` unless the extension names something better, which
    /// is what the mobile client sends for every file attachment
    /// (`media_upload.dart:326`). It matters less than it looks: the relay sniffs the
    /// bytes and stores what *it* concludes, so this is a hint, and the descriptor
    /// that comes back carries the truth.
    var mimeType: String {
        guard let type = UTType(filenameExtension: url.pathExtension),
              let mime = type.preferredMIMEType
        else { return "application/octet-stream" }
        return mime
    }
}
