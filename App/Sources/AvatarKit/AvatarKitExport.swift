import BuzzKit
import SwiftUI
import UIKit

/// Turns a built avatar into the PNG bytes a profile publishes, at one of two sizes.
///
/// # Why there are two sizes rather than one
///
/// The emoji avatar rides inline because it is a hundred bytes of SVG. This one is a stack of
/// drawings, and encoded it is tens of kilobytes — enough that *where the bytes go* is a real
/// question with two different answers:
///
/// - The account editor **uploads**. It takes the photo's route — draw, encode, scrub, `PUT` —
///   and what lands in `picture` is the URL the relay gives back. Its only size limit is the
///   blob store's, so it exports at ``side``.
/// - The arrival walk **embeds**, because a fresh identity on an unfamiliar relay cannot count
///   on a URL being readable at all (§ ``AppEnvironment/publishableValue(for:)``). Its bytes
///   have to fit inside a kind-0 next to a name, so it exports at ``inlineSide``.
///
/// Every surface in the app draws both without being told which it was handed: a `data:` URI
/// is a source ``RemoteImageLoader`` resolves like any other.
@MainActor
enum AvatarKitExport {
    enum Failure: Error {
        /// The canvas produced no bitmap.
        case couldNotDraw
        /// The bitmap would not encode as a PNG.
        case couldNotEncode
    }

    /// The side of an *uploaded* square, in pixels.
    ///
    /// The largest this app draws an avatar is ``AccountView``'s 112pt, which on a 3x screen
    /// is 336 real pixels; the editor's own preview is 396. 512 clears both with room for a
    /// screen that has not shipped yet, and is small enough that the file stays tens of
    /// kilobytes rather than hundreds.
    static let side: CGFloat = 512

    /// The side of a square that has to ride *inside* the event, in pixels.
    ///
    /// Smaller than ``side`` because it is spending a budget rather than a blob store: base64
    /// costs four bytes per three, and the finished kind-0 has to fit inside
    /// `OutboxPolicy.maxContentBytes` — 65,536. Both bounds were measured over 320 shuffled
    /// avatars rather than guessed, and they close on this number from opposite directions.
    ///
    /// **From below**, 336px is the most this app ever draws — 112pt at 3x — and
    /// ``RemoteImageLoader``'s thumbnail cap only ever shrinks a source, never enlarges one, so
    /// anything under 336 is drawn soft at the one size where it would be noticed. 384 clears
    /// that by 14%; 352 clears it by 5%; 320 does not clear it.
    ///
    /// **From above**, the worst of those 320 avatars at 384px is a 32,140-byte PNG and a
    /// 43,700-byte body: 21,836 bytes spare, which is room for a picture half again as large as
    /// the largest one measured. 512 is what will not do. Its worst body is 62,601 bytes —
    /// 2,935 spare — and that worst case *grew* from 55,167 bytes at 48 samples to 62,601 at
    /// 320, which is a distribution whose real maximum is over the ceiling rather than near it.
    /// An avatar that breached it would be dropped silently, so the margin has to be the kind
    /// nothing unseen can cross.
    static let inlineSide: CGFloat = 384

    /// `avatar` as PNG bytes the relay will accept, drawn `side` pixels square.
    ///
    /// The side is a parameter rather than a constant because the two things this app does
    /// with a finished avatar have different ceilings: an upload's only limit is the blob
    /// store's, and an inline one has to fit inside a kind-0 (§ ``inlineSide``).
    static func pngData(for avatar: AvatarKitAvatar, side: CGFloat = AvatarKitExport.side) throws -> Data {
        guard let image = render(avatar, side: side) else { throw Failure.couldNotDraw }
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
    private static func render(_ avatar: AvatarKitAvatar, side: CGFloat) -> UIImage? {
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
