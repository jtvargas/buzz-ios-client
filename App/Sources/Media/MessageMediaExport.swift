import BuzzKit
import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

/// Getting an attachment *out* of the app: onto the camera roll, or into the share sheet.
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
            case .download: "Hive couldn't download this picture. Check your connection and try again."
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
    static func fetch(_ media: MessageMedia, session: URLSession) async throws -> URL {
        guard let source = URL(string: media.url) else { throw Failure.download }
        let (data, response) = try await fetchData(from: source, session: session)
        let name = filename(for: media, responseMIMEType: (response as? HTTPURLResponse)?.mimeType)
        do {
            let file = try destination(for: media, named: name)
            try data.write(to: file, options: .atomic)
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
    static func filename(for media: MessageMedia, responseMIMEType: String?) -> String {
        let stem = URL(string: media.url)?.deletingPathExtension().lastPathComponent
        let name = (stem?.isEmpty == false ? stem! : "image")
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
}

// MARK: - Fetching

private extension MessageMediaExport {
    static func fetchData(from source: URL, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            let (data, response) = try await session.data(from: source)
            // A media host that is reachable but has lost the object answers with a page, not
            // with a transport error — so an unchecked `data` is how an HTML 404 ends up in
            // someone's camera roll.
            if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                throw Failure.download
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
    /// twice cannot append. The directory is emptied first rather than the file overwritten:
    /// a second fetch may resolve to a *different* extension than the first, and the stale
    /// sibling would be the one the share sheet happened to pick up.
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
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(name)
    }

    static func isPhotoLibraryAdditionAllowed() async -> Bool {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let status = current == .notDetermined
            ? await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            : current
        return status == .authorized || status == .limited
    }
}
