import BuzzKit
import Foundation
import UIKit

/// Turns what a picker handed over into bytes the relay will store, plus a small
/// preview to draw while they go up.
///
/// # The one conversion, and why it is unavoidable
///
/// An iPhone camera writes HEIC and the relay stores jpeg, png, gif and webp —
/// see ``MediaUploadClient/supportedImageTypes``. So a photo shot on this device
/// has to be re-encoded before it can be sent, and that cost is why picking a
/// picture is not instant. The mobile client pays exactly the same one.
///
/// Everything the relay *does* store is passed through untouched. That is not
/// laziness: a GIF, an animated PNG or an animated WebP put through a re-encode
/// comes back as a single still frame, and it reports success while doing it.
///
/// # Where this runs
///
/// `nonisolated` and `async`, so it runs on the generic executor rather than
/// wherever it was called from. Decoding a 12-megapixel photo and re-drawing it
/// is tens of milliseconds of work per picture; on the main actor that is the
/// composer's own keyboard animation dropping frames.
enum ComposerImagePreparation {
    /// A picture ready to be uploaded, and something to show meanwhile.
    struct Prepared: Sendable {
        /// The bytes to `PUT`, in a format the relay stores.
        let data: Data
        /// The type those bytes are in.
        let mimeType: String
        /// A small JPEG of the picture, for the composer's thumbnail.
        ///
        /// Bytes rather than a `UIImage` deliberately. `UIImage` is not `Sendable`,
        /// so handing one back from here to the main actor would need an
        /// `@unchecked` conformance to be justified; decoding a 288-pixel JPEG on
        /// the main actor instead is well under a millisecond and needs no
        /// justification at all.
        let preview: Data
    }

    enum Failure: Error, Equatable {
        /// ImageIO could not open these bytes, so whatever was picked, it was not
        /// a picture this device can read.
        case notAPicture
        /// It is a picture, and re-encoding it produced nothing.
        case couldNotConvert
    }

    /// The longest edge of the composer thumbnail, in pixels — 72pt of tile at 3×,
    /// with nothing spare. A thumbnail is drawn once and thrown away when the
    /// message goes, so there is no reason to hold more of it than is shown.
    static let previewPixelSize: CGFloat = 288

    /// Quality for the HEIC conversion. High enough that the conversion is not
    /// what an author notices about their own photo, low enough that a 12-megapixel
    /// picture does not become a bigger file than the one it came from.
    static let conversionQuality: CGFloat = 0.9

    /// Quality for the thumbnail, which is 288 pixels wide and never looked at
    /// closely.
    static let previewQuality: CGFloat = 0.8

    /// Reads `data`, converting it only if the relay would not store it as it is.
    nonisolated static func prepare(_ data: Data) async throws -> Prepared {
        // Also the "is this a picture at all" test: ImageIO opens every format
        // this app can send and every format it cannot, so a payload it will not
        // open is not one worth uploading to find out. Transform is on, so a photo
        // shot in portrait thumbnails upright.
        guard let thumbnail = RemoteImageLoader.downsample(data, maxPixelSize: previewPixelSize),
              let preview = thumbnail.jpegData(compressionQuality: previewQuality)
        else { throw Failure.notAPicture }

        if let format = ImageByteFormat.detect(data), format.isStoredByRelay {
            return Prepared(data: data, mimeType: format.mimeType, preview: preview)
        }

        guard let converted = convertToJPEG(data) else { throw Failure.couldNotConvert }
        return Prepared(data: converted, mimeType: ImageByteFormat.jpeg.mimeType, preview: preview)
    }

    /// Re-encodes to JPEG, upright.
    ///
    /// Through `UIImage` rather than straight from the `CGImage`, and this is the
    /// part that is easy to get wrong: a photo shot in portrait is stored as
    /// landscape pixels plus an EXIF rotation, and an encoder handed the pixels
    /// alone publishes it on its side. `UIImage` carries that rotation as
    /// `imageOrientation`, and re-drawing bakes it into the pixels where nothing
    /// downstream can lose it.
    private nonisolated static func convertToJPEG(_ data: Data) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let upright = image.imageOrientation == .up ? image : redrawnUpright(image)
        return upright.jpegData(compressionQuality: conversionQuality)
    }

    /// The same picture with its rotation applied to the pixels.
    ///
    /// `size` on an oriented `UIImage` is already the *displayed* size — width and
    /// height swapped for a quarter turn — and `draw(in:)` applies the rotation, so
    /// drawing into a context of that size is all that is needed.
    private nonisolated static func redrawnUpright(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.preferred()
        // The source is a file, so its own scale is 1 and its size is in pixels.
        // Taking the screen's scale here would render a picture 2 or 3 times larger
        // than the one that was picked.
        format.scale = image.scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
