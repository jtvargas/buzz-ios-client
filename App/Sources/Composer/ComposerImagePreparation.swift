import BuzzKit
import Foundation
import UIKit

/// Turns what a picker handed over into bytes the relay will store, plus a small
/// preview to draw while they go up.
///
/// # Nothing is passed through
///
/// The first version of this file converted HEIC and let every other format go up
/// as it was, on the reasoning that the relay stores JPEG, PNG, GIF and WebP. That
/// shipped, and the owner's own photo library failed on it within minutes.
///
/// The relay does not merely store those formats, it stores them **bare**. A JPEG
/// may carry a canonical JFIF header and an Adobe marker and nothing else; EXIF,
/// the colour profile, XMP and comments are all refused, and every photograph an
/// iPhone takes carries the first two. So the format was never the question. See
/// ``ImageMetadataScrub`` for the relay's own rules, which this mirrors.
///
/// Which means there is a privacy property here worth stating plainly, because it
/// is the reason to do this even where the relay would tolerate it: **EXIF on an
/// iPhone photo carries GPS.** Everything below runs before a byte leaves the
/// device, so a picture sent from Hive does not publish where it was taken.
///
/// # Three routes, and why the picture decides
///
/// - **Stills** are re-rendered into sRGB, re-encoded, then scrubbed. The render is
///   what removes the *need* for a colour profile: dropping a Display P3 profile
///   while leaving P3 pixels behind it would leave the picture to be read as sRGB
///   and come out oversaturated. The scrub afterwards is not belt-and-braces — the
///   system encoder still writes segments the relay refuses.
/// - **Animations** are scrubbed structurally and never decoded. A GIF or an APNG
///   put through a decode comes back as one frame, and reports success while doing
///   it.
/// - **WebP** cannot be encoded by this device at all, so a still one becomes a PNG.
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
        /// The bytes to `PUT`, in a format the relay stores and free of metadata.
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
        /// An animation carries something that cannot be taken off without
        /// decoding it, and decoding it would cost the animation.
        case animationCannotBeCleaned
    }

    /// The longest edge of the composer thumbnail, in pixels — 72pt of tile at 3×,
    /// with nothing spare. A thumbnail is drawn once and thrown away when the
    /// message goes, so there is no reason to hold more of it than is shown.
    static let previewPixelSize: CGFloat = 288

    /// Quality for the re-encode.
    ///
    /// 1.0, which is the mobile client's (`MediaSanitizer.encodeJpeg`), and matched
    /// deliberately rather than tuned: every still is re-encoded now, including one
    /// that arrived as a JPEG, so this is a *generational* loss on a picture that
    /// has already been compressed once. At 1.0 that loss is negligible and the
    /// file is larger; this is the dial to turn if upload time on a slow connection
    /// ever matters more than the last fraction of fidelity.
    static let conversionQuality: CGFloat = 1.0

    /// Quality for the thumbnail, which is 288 pixels wide and never looked at
    /// closely.
    static let previewQuality: CGFloat = 0.8

    /// Reads `data` and returns bytes the relay will accept.
    nonisolated static func prepare(_ data: Data) async throws -> Prepared {
        // Also the "is this a picture at all" test: ImageIO opens every format
        // this app can send and every format it cannot, so a payload it will not
        // open is not one worth uploading to find out. Transform is on, so a photo
        // shot in portrait thumbnails upright.
        guard let thumbnail = RemoteImageLoader.downsample(data, maxPixelSize: previewPixelSize),
              let preview = thumbnail.jpegData(compressionQuality: previewQuality)
        else { throw Failure.notAPicture }

        let cleaned = try clean(data)
        return Prepared(data: cleaned.data, mimeType: cleaned.mimeType, preview: preview)
    }

    /// The route this picture takes, and the bytes at the end of it.
    private nonisolated static func clean(_ data: Data) throws -> (data: Data, mimeType: String) {
        do {
            switch ImageByteFormat.detect(data) {
            case .gif:
                // Always structural: a still GIF is rare, and telling it apart costs
                // more than scrubbing one that did not need it.
                return (try ImageMetadataScrub.scrubGIF(data), ImageByteFormat.gif.mimeType)
            case .png where ImageMetadataScrub.isAnimatedPNG(data):
                return (
                    try ImageMetadataScrub.scrubPNG(data, isAnimated: true),
                    ImageByteFormat.png.mimeType
                )
            case .webp where ImageMetadataScrub.isAnimatedWebP(data):
                return (try ImageMetadataScrub.scrubWebP(data), ImageByteFormat.webp.mimeType)
            case .png, .webp:
                // A still WebP leaves as a PNG: this device has no WebP encoder, and
                // re-rendering is the only way to be rid of a colour profile.
                return (try encodedPNG(data), ImageByteFormat.png.mimeType)
            case .jpeg, .heic, .none:
                // `nil` is every format nothing here recognises. It reached this line
                // by opening in ImageIO above, so it is a picture; JPEG is what it
                // becomes.
                return (try encodedJPEG(data), ImageByteFormat.jpeg.mimeType)
            }
        } catch ImageMetadataScrub.Failure.unremovableFromAnimation {
            throw Failure.animationCannotBeCleaned
        }
    }

    /// Re-renders in sRGB, encodes, and scrubs what the encoder still wrote.
    private nonisolated static func encodedJPEG(_ data: Data) throws -> Data {
        guard let upright = renderedInSRGB(data),
              let encoded = upright.jpegData(compressionQuality: conversionQuality)
        else { throw Failure.couldNotConvert }
        return try ImageMetadataScrub.scrubJPEG(encoded)
    }

    /// The same for PNG, which keeps transparency where JPEG would flatten it.
    private nonisolated static func encodedPNG(_ data: Data) throws -> Data {
        guard let upright = renderedInSRGB(data), let encoded = upright.pngData() else {
            throw Failure.couldNotConvert
        }
        return try ImageMetadataScrub.scrubPNG(encoded)
    }

    /// The picture redrawn into standard-range sRGB, with its rotation applied to the
    /// pixels.
    ///
    /// Two things happen here and both are load-bearing.
    ///
    /// `preferredRange = .standard` is what makes the colour profile unnecessary. The
    /// default is the *display's* range, which on every recent iPhone is Display P3,
    /// and an encoder handed wide-gamut pixels writes a profile to describe them —
    /// which is the `APP2` segment the relay refuses. Rendering into sRGB means the
    /// pixels need no description.
    ///
    /// Redrawing also bakes in the orientation. A photo shot in portrait is landscape
    /// pixels plus an EXIF rotation, and this strips EXIF — so a picture that was only
    /// upright *because of the tag* would publish on its side. `UIImage.size` on an
    /// oriented image is already the displayed size and `draw(in:)` applies the
    /// rotation, so drawing into a context of that size is all that is needed.
    private nonisolated static func renderedInSRGB(_ data: Data) -> UIImage? {
        guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else {
            return nil
        }
        let format = UIGraphicsImageRendererFormat()
        // The source is a file, so its own scale is 1 and its size is in pixels.
        // Taking the screen's scale here would render a picture 2 or 3 times larger
        // than the one that was picked.
        format.scale = image.scale
        // Not opaque: a PNG with transparency would otherwise come back on black.
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }
}
