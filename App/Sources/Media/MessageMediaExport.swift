import BuzzKit
import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

/// Getting an attachment's original bytes onto disk for preview, saving, or sharing.
///
/// # Why this fetches the picture again
///
/// What is on screen is not what should leave. ``RemoteImageLoader`` downsamples with ImageIO
/// to the pixel size of the box it is about to fill, off the main thread, because that is what
/// keeps a list of pictures scrolling — so the bitmap the row is holding is a few hundred
/// points wide and has been re-encoded on the way. Saving that to someone's photo library, or
/// AirDropping it, would hand them a thumbnail of the thing they asked for.
///
/// So both actions run on the *original bytes*, fetched once and written to a file. That file
/// is also what makes the share sheet behave: `ShareLink` over a file URL gives every receiver
/// the real type and a real name — Mail attaches a `.jpeg`, Photos imports it as the format it
/// was posted in — where an in-memory `UIImage` arrives re-encoded and anonymous.
///
/// # Why a file and not `Data`
///
/// `PHAssetCreationRequest.addResource(with:fileURL:options:)` hands Photos the bytes as
/// authored. The `Data` overload does the same, but the file also serves the share sheet, and
/// fetching the same picture twice for two rows of one sheet is the kind of thing that is
/// invisible on a laptop and obvious on a phone holding a 12-megapixel photo.
enum MessageMediaExport {
    /// Why an export did not happen, in the words the reader is shown.
    ///
    /// Deliberately few, and none of them mention a status code: a person who tapped Save
    /// Image can act on "there was no room" and on "Hive is not allowed to", and can do
    /// nothing whatever with a 502.
    enum Failure: LocalizedError, Equatable {
        /// The bytes never arrived — off the tailnet, or the media host said no.
        case download
        /// The reader has refused, or has been refused, permission to add to the library.
        case photoLibraryDenied
        /// Photos accepted the request and then did not complete it.
        case save

        var errorDescription: String? {
            switch self {
            case .download: "Hive couldn't download this attachment. Check your connection and try again."
            case .photoLibraryDenied:
                "Hive isn't allowed to add to your photo library. You can change that in Settings."
            case .save: "Hive couldn't save this picture to your photo library."
            }
        }
    }

    /// The session every export runs over.
    ///
    /// One for the process, not one per sheet: a `URLSession` owns an operation queue and a
    /// delegate and is only released when it is invalidated, so building one each time a
    /// reader double-tapped a picture would accumulate them for the life of the app.
    ///
    /// The configuration is the loader's own — a 15-second *idle* timeout, so a host that is
    /// not there fails in fifteen seconds rather than sixty, while a slow download that is
    /// still arriving is never cut off. See ``RemoteImageLoader/makeSession()``.
    static let session = RemoteImageLoader.makeSession()

    /// Fetches the attachment's original bytes and returns the file they were written to.
    ///
    /// The grant is the same one the image loaders fetch with, and it is needed here for the
    /// same reason: a relay with `require_media_get_auth` on refuses an unsigned read, so
    /// without it the picture a reader is looking at cannot be saved or shared. `nil` sends
    /// an unauthenticated request, which is what every relay that does not ask for one
    /// expects.
    static func fetch(
        _ media: MessageMedia,
        session: URLSession,
        authorization: (any MediaReadAuthorizing)? = nil
    ) async throws -> URL {
        guard let source = URL(string: media.url) else { throw Failure.download }
        let (data, response) = try await fetchData(
            media, from: source, session: session, authorization: authorization
        )
        let name = filename(for: media, responseMIMEType: (response as? HTTPURLResponse)?.mimeType)
        do {
            let file = try destination(for: media, named: name)
            try data.write(to: file, options: .atomic)
            pruneSiblings(of: file)
            return file
        } catch {
            throw Failure.download
        }
    }

    /// Adds a fetched file to the photo library, asking for add-only access first.
    ///
    /// Add-only rather than full access on purpose: Hive never reads the library, and the
    /// prompt a reader sees should say what the app will actually do. `.limited` counts as
    /// granted — it is a *read* restriction, and an add-only client is not reading.
    static func addToPhotoLibrary(_ file: URL) async throws {
        guard await isPhotoLibraryAdditionAllowed() else { throw Failure.photoLibraryDenied }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, fileURL: file, options: nil)
            }
        } catch {
            throw Failure.save
        }
    }

    /// The name the file is given, which is the name the receiver sees.
    ///
    /// Relay media is content-addressed — the path is a digest with no extension — so the
    /// name has to be built rather than read off the URL. The extension is what actually
    /// matters: it is how the share sheet decides which apps can accept the picture, and a
    /// file with none is offered to almost nothing.
    ///
    /// The declared type is preferred over the served one because the author's `imeta` tag is
    /// the only place an animation is reliably distinguished from a still — a relay that
    /// serves `image/jpeg` for everything would otherwise turn every GIF into a `.jpeg` that
    /// does not move. A URL that already carries a plausible extension is trusted last, and a
    /// picture that declares nothing at all is a `.jpg`, which is what it will be.
    ///
    /// The stem is capped, and that is not tidiness. A `data:` URI is a supported source here
    /// — ``RemoteImageLoader`` decodes them — and its "last path component" is the entire
    /// base64 payload. A filename over 255 bytes cannot be written on any filesystem this app
    /// runs on, so an unguarded stem turns a picture pasted as a data URI into a save that
    /// fails with a message about the download.
    static let maximumStemLength = 64

    static func filename(for media: MessageMedia, responseMIMEType: String?) -> String {
        if media.kind == .file {
            if let filename = safeFilename(media.filename) { return filename }
            return genericFilename(for: media, responseMIMEType: responseMIMEType)
        }

        let stem = URL(string: media.url)?.deletingPathExtension().lastPathComponent
        let name = stem.flatMap { $0.isEmpty || $0.count > maximumStemLength ? nil : $0 } ?? "image"
        let declared = media.mimeType.flatMap { UTType(mimeType: $0) }
        let served = responseMIMEType.flatMap { UTType(mimeType: $0) }
        let carried = (URL(string: media.url)?.pathExtension).flatMap {
            $0.isEmpty ? nil : UTType(filenameExtension: $0)
        }
        let type = [declared, served, carried]
            .compactMap { $0 }
            .first { $0.conforms(to: .image) }
        return "\(name).\(type?.preferredFilenameExtension ?? "jpg")"
    }

    private static func genericFilename(for media: MessageMedia, responseMIMEType: String?) -> String {
        let url = URL(string: media.url)
        let stem = url?.deletingPathExtension().lastPathComponent
        let name = stem.flatMap { $0.isEmpty || $0.count > maximumStemLength ? nil : $0 } ?? "file"
        let declared = media.mimeType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        let served = responseMIMEType.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension }
        let carried = url?.pathExtension
        let extensionName = [declared, served, carried]
            .compactMap { value in value.flatMap { $0.isEmpty ? nil : $0 } }
            .first ?? "bin"
        return "\(name).\(extensionName)"
    }

    private static func safeFilename(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let component = raw.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = component.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, cleaned != ".", cleaned != ".." else { return nil }
        return cleaned.count <= 200
            ? cleaned
            : String(cleaned.prefix(160)) + String(cleaned.suffix(40))
    }
}

// MARK: - Fetching

private extension MessageMediaExport {
    static func fetchData(
        _ media: MessageMedia,
        from source: URL,
        session: URLSession,
        authorization: (any MediaReadAuthorizing)?
    ) async throws -> (Data, URLResponse) {
        do {
            var request = URLRequest(url: source)
            if let header = await authorization?.authorization(for: source) {
                request.setValue(header, forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: request)
            // A media host that is reachable but has lost the object answers with a *page*,
            // not with a transport error — so an unchecked body is how an HTML 404 ends up
            // named `.jpg` in front of the share sheet. Both halves are needed: some relays
            // serve the error at 200, and some serve a real picture as
            // `application/octet-stream`, which is why an unrecognised type passes and only a
            // type that is positively *not* an image is refused.
            //
            // A file cannot use that test — `application/octet-stream` is the *expected*
            // answer for one, and the relay names an unsniffable blob `.bin` — so it gets
            // the narrowest form of the same guard instead. A served page is still a lost
            // object, and Quick Look would render the error page as the document. Only a
            // file that declares itself a page may be served as one, and the relay refuses
            // to store those in the first place.
            if let http = response as? HTTPURLResponse {
                guard (200 ..< 300).contains(http.statusCode) else { throw Failure.download }
                let served = http.mimeType.flatMap { UTType(mimeType: $0) }
                switch media.kind {
                case .image:
                    if let served, !served.conforms(to: .image) { throw Failure.download }
                case .file, .video:
                    // Video shares the file's test rather than the picture's: `video/mp4`
                    // is positively not an image, so the branch above would refuse every
                    // one of them the day a video is exportable.
                    let declared = media.mimeType.flatMap { UTType(mimeType: $0) }
                    if let served, served.conforms(to: .html), declared?.conforms(to: .html) != true {
                        throw Failure.download
                    }
                }
            }
            guard !data.isEmpty else { throw Failure.download }
            return (data, response)
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.download
        }
    }

    /// Where the fetched bytes are written.
    ///
    /// One directory per attachment, named by a digest of its URL, so two pictures that were
    /// posted with the same filename cannot overwrite each other and re-opening the same one
    /// twice cannot append.
    ///
    /// The system's temporary directory is the right home for it — it is purged for us, and
    /// nothing here is worth surviving a launch.
    static func destination(for media: MessageMedia, named name: String) throws -> URL {
        let digest = SHA256.hash(data: Data(media.url.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedMedia", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    /// Removes anything left in the directory that is not the file just written.
    ///
    /// A second fetch of the same picture can resolve to a *different* extension than the
    /// first — the author's tag is preferred over the served type, and a relay that changes
    /// what it serves changes the answer — and the stale sibling is then a second candidate in
    /// a directory the share sheet is pointed at. Cleared *after* the write rather than by
    /// emptying the directory before it, so there is never a moment when the picture the
    /// reader asked for is absent.
    ///
    /// Best-effort throughout: a file that will not delete is a stale sibling, not a failed
    /// export, and refusing the save over it would be the wrong trade.
    static func pruneSiblings(of file: URL) {
        let directory = file.deletingLastPathComponent()
        let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for stale in contents ?? [] where stale.lastPathComponent != file.lastPathComponent {
            try? FileManager.default.removeItem(at: stale)
        }
    }

    static func isPhotoLibraryAdditionAllowed() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current
        return status == .authorized || status == .limited
    }
}
