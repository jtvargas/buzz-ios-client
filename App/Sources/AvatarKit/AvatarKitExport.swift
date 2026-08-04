import BuzzKit
import SwiftUI
import UIKit

/// Turns a built avatar into the PNG that gets uploaded.
///
/// # Why this is not a data URI
///
/// The emoji avatar rides inline because it is a hundred bytes of SVG. This one is a stack
/// of drawings; encoded it is tens of kilobytes, and a kind‑0 is capped at
/// `OutboxPolicy.maxContentBytes`. So it takes the photo's route — draw, encode, scrub,
/// `PUT` — and what lands in `picture` is the URL the relay gives back, which every surface
/// in the app already knows how to draw.
@MainActor
enum AvatarKitExport {
    enum Failure: Error {
        /// The canvas produced no bitmap.
        case couldNotDraw
        /// The bitmap would not encode as a PNG.
        case couldNotEncode
    }

    /// The side of the exported square, in pixels.
    ///
    /// The largest this app draws an avatar is ``AccountView``'s 112pt, which on a 3x screen
    /// is 336 real pixels; the editor's own preview is 396. 512 clears both with room for a
    /// screen that has not shipped yet, and is small enough that the file stays tens of
    /// kilobytes rather than hundreds.
    static let side: CGFloat = 512

    /// `avatar` as PNG bytes the relay will accept.
    static func pngData(for avatar: AvatarKitAvatar) throws -> Data {
        guard let image = render(avatar) else { throw Failure.couldNotDraw }
        guard let encoded = image.pngData() else { throw Failure.couldNotEncode }
        // Required even for bytes this app just encoded: the system encoder still writes
        // segments the relay refuses. The composer's rule, and the same call.
        return try ImageMetadataScrub.scrubPNG(encoded)
    }

    /// The MIME type ``pngData(for:)`` produces, named here so the caller cannot disagree
    /// with the encoder.
    static let mimeType = "image/png"

    /// Draws the avatar offscreen.
    ///
    /// Two passes, and the second one is the load-bearing one. `ImageRenderer` composes the
    /// very view the editor is showing — which is the only way the exported picture and the
    /// preview cannot drift — but it offers no say over the colour range it renders into,
    /// and the default is the *display's*, which on every recent iPhone is Display P3. An
    /// encoder handed wide-gamut pixels writes a profile to describe them, and that profile
    /// is the chunk the relay refuses. So the composed image is redrawn once through
    /// `UIGraphicsImageRenderer` with `preferredRange = .standard`, exactly as
    /// ``ComposerImagePreparation`` does for a photo: in sRGB the pixels need no description.
    ///
    /// `opaque = false` throughout, because the transparent ground is one of the nine.
    private static func render(_ avatar: AvatarKitAvatar) -> UIImage? {
        let renderer = ImageRenderer(content: AvatarKitCanvas(avatar: avatar, side: side))
        // The canvas is asked for `side` *points* and this writes one pixel per point, so
        // the bitmap is `side` pixels square. Anything else would scale it twice.
        renderer.scale = 1
        renderer.isOpaque = false
        guard let composed = renderer.uiImage else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        format.preferredRange = .standard

        let box = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(size: box.size, format: format).image { _ in
            composed.draw(in: box)
        }
    }
}
